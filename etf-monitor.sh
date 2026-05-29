#!/usr/bin/env bash
# Daily ETF price monitor — fetches LSE prices from Yahoo Finance, calculates
# changes vs the 10 May 2026 baselines, and posts a summary Slack DM.
#
# Requirements: curl, jq, bc, awk  (all present on ubuntu-latest)
# Environment:  SLACK_BOT_TOKEN   — Slack bot OAuth token
#                                   (scopes: chat:write, im:write)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

SLACK_USER="U0ABZ5ER8N7"
DATE_STR=$(date +"%d %b %Y")

declare -A YF_TICKER BASELINE LABEL
YF_TICKER=( [XDEW]="XDEW.L" [MWEP]="MWEP.L" [VWRP]="VWRP.L" [CSH2]="CSH2.L" )
BASELINE=(  [XDEW]="107.00" [MWEP]="482.25" [VWRP]="134.00" [CSH2]="1233.00" )
LABEL=(     [XDEW]="equal weight S&P500" [MWEP]="equal weight global" \
            [VWRP]="cap weighted global" [CSH2]="cash" )
ORDER=(XDEW MWEP VWRP CSH2)

# ── Yahoo Finance session ─────────────────────────────────────────────────────

YF_COOKIE=""
YF_CRUMB=""

yf_init() {
    YF_COOKIE=$(mktemp)
    trap 'rm -f "$YF_COOKIE"' EXIT

    curl -s -c "$YF_COOKIE" -L "https://finance.yahoo.com/" \
        -A "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0" \
        -H "Accept-Language: en-GB,en;q=0.5" \
        > /dev/null

    YF_CRUMB=$(curl -s -b "$YF_COOKIE" \
        "https://query2.finance.yahoo.com/v1/test/getcrumb" \
        -A "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0")

    if [[ -z "$YF_CRUMB" || "$YF_CRUMB" == *"Too Many"* || "$YF_CRUMB" == *"error"* ]]; then
        echo "ERROR: Could not obtain Yahoo Finance crumb (got: ${YF_CRUMB:-empty})" >&2
        exit 1
    fi
}

# fetch_quote <YF_TICKER>  →  stdout: "price_gbp|day_change_pct"
# price_gbp and day_change_pct are bare numbers, or "N/A" on failure.
fetch_quote() {
    local ticker="$1"
    local resp price currency day_pct

    resp=$(curl -s -b "$YF_COOKIE" \
        "https://query2.finance.yahoo.com/v10/finance/quoteSummary/${ticker}?crumb=${YF_CRUMB}&modules=price" \
        -A "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0" \
        -H "Accept: application/json" \
        --max-time 15 2>&1)

    price=$(echo    "$resp" | jq -r '.quoteSummary.result[0].price.regularMarketPrice.raw         // "N/A"')
    currency=$(echo "$resp" | jq -r '.quoteSummary.result[0].price.currency                       // "N/A"')
    day_pct=$(echo  "$resp" | jq -r '.quoteSummary.result[0].price.regularMarketChangePercent.raw // "N/A"')

    if [[ "$price" == "N/A" ]]; then
        echo "N/A|N/A"
        return
    fi

    # LSE stocks are quoted in GBX (pence) — convert to GBP
    if [[ "$currency" == "GBp" || "$currency" == "GBX" ]]; then
        price=$(echo "scale=6; $price / 100" | bc)
    fi

    # regularMarketChangePercent.raw is a decimal fraction (0.015 = 1.5%) — scale to %
    if [[ "$day_pct" != "N/A" ]]; then
        day_pct=$(echo "scale=6; $day_pct * 100" | bc)
    fi

    echo "${price}|${day_pct}"
}

# ── Formatting helpers ────────────────────────────────────────────────────────

pct_vs_baseline() {
    echo "scale=6; ($1 - $2) / $2 * 100" | bc
}

fmt_price() {
    printf "£%.2f" "$1"
}

fmt_pct() {
    awk -v v="$1" 'BEGIN { printf "%+.1f%%", v }'
}

signal() {
    local pct="$1"
    [[ "$pct" == "N/A" ]] && { echo "⚠️"; return; }
    awk -v v="$pct" 'BEGIN {
        if (v >  0.3) print "🟢"
        else if (v < -0.3) print "🔴"
        else print "⚪"
    }'
}

abs_pct() {
    awk -v v="$1" 'BEGIN { printf "%.6f", (v < 0 ? -v : v) }'
}

# ── Slack ─────────────────────────────────────────────────────────────────────

slack_open_dm() {
    curl -s -X POST "https://slack.com/api/conversations.open" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"users\":\"${SLACK_USER}\"}" \
        | jq -r '.channel.id // empty'
}

slack_post() {
    local channel="$1" text="$2"
    local resp ok

    resp=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$(jq -n --arg ch "$channel" --arg txt "$text" \
              '{channel: $ch, text: $txt, mrkdwn: true}')")

    ok=$(echo "$resp" | jq -r '.ok')
    if [[ "$ok" != "true" ]]; then
        echo "ERROR posting to Slack: $(echo "$resp" | jq -r '.error // .')" >&2
        exit 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    : "${SLACK_BOT_TOKEN:?SLACK_BOT_TOKEN env var must be set}"

    yf_init

    declare -A PRICE DAY_PCT BASE_PCT
    local -a UNAVAIL=()

    for key in "${ORDER[@]}"; do
        local result
        result=$(fetch_quote "${YF_TICKER[$key]}")
        PRICE[$key]="${result%%|*}"
        DAY_PCT[$key]="${result##*|}"

        if [[ "${PRICE[$key]}" == "N/A" ]]; then
            UNAVAIL+=("$key")
            BASE_PCT[$key]="N/A"
        else
            BASE_PCT[$key]=$(pct_vs_baseline "${PRICE[$key]}" "${BASELINE[$key]}")
        fi
    done

    # ── Table rows ────────────────────────────────────────────────────────────
    local table=""
    for key in "${ORDER[@]}"; do
        local price_str base_str sig
        if [[ "${PRICE[$key]}" == "N/A" ]]; then
            price_str="N/A"
            base_str="N/A"
            sig="⚠️"
        else
            price_str=$(fmt_price "${PRICE[$key]}")
            base_str=$(fmt_pct "${BASE_PCT[$key]}")
            sig=$(signal "${DAY_PCT[$key]}")
        fi
        table+="| ${key} (${LABEL[$key]}) | ${price_str} | ${base_str} | ${sig} |"$'\n'
    done
    table="${table%$'\n'}"  # strip trailing newline for clean heredoc embedding

    # ── Equal weight vs cap weight gap (XDEW vs VWRP) ────────────────────────
    local gap_line
    if [[ "${BASE_PCT[XDEW]}" != "N/A" && "${BASE_PCT[VWRP]}" != "N/A" ]]; then
        local gap abs_gap direction
        gap=$(awk -v a="${BASE_PCT[XDEW]}" -v b="${BASE_PCT[VWRP]}" 'BEGIN { printf "%.6f", a - b }')
        abs_gap=$(awk -v v="$gap" 'BEGIN { printf "%.1f", (v < 0 ? -v : v) }')
        direction=$(awk -v v="$gap" 'BEGIN { print (v >= 0) ? "outperforming" : "underperforming" }')
        gap_line="*Equal weight vs cap weight gap: XDEW ${direction} VWRP by ${abs_gap}% since baseline*"
    else
        gap_line="*Equal weight vs cap weight gap: data unavailable*"
    fi

    # ── Alerts (>2% single day OR >10% from baseline) ─────────────────────────
    local alerts=""
    for key in "${ORDER[@]}"; do
        [[ "${PRICE[$key]}" == "N/A" ]] && continue

        local day_abs base_abs day_trigger base_trigger
        day_abs=$(abs_pct "${DAY_PCT[$key]}")
        base_abs=$(abs_pct "${BASE_PCT[$key]}")
        day_trigger=$(awk  -v v="$day_abs"  'BEGIN { print (v > 2)  ? 1 : 0 }')
        base_trigger=$(awk -v v="$base_abs" 'BEGIN { print (v > 10) ? 1 : 0 }')

        if   [[ "$day_trigger"  == "1" ]]; then
            alerts+="${key} moved $(fmt_pct "${DAY_PCT[$key]}") today. "
        elif [[ "$base_trigger" == "1" ]]; then
            alerts+="${key} is $(fmt_pct "${BASE_PCT[$key]}") from baseline. "
        fi
    done

    local alert_block=""
    [[ -n "$alerts" ]] && alert_block=$'\n\n'"🚨 *ALERT*: ${alerts}"

    local unavail_block=""
    [[ ${#UNAVAIL[@]} -gt 0 ]] && \
        unavail_block=$'\n\n'"⚠️ *Data unavailable for:* ${UNAVAIL[*]} — check tickers manually."

    # ── Compose and post ──────────────────────────────────────────────────────
    local msg
    msg=$(cat <<EOF
📊 *Daily ETF Monitor — ${DATE_STR}*

| ETF | Price | vs Baseline | Signal |
|-----|-------|------------|--------|
${table}

${gap_line}

💧 *Dry powder status:* £240k in CSH2. Deploy trigger: XDEW falls to ~£91 (-15%) or MWEP falls to ~£410 (-15%).${alert_block}${unavail_block}
EOF
)

    local channel
    channel=$(slack_open_dm)
    if [[ -z "$channel" ]]; then
        echo "ERROR: Could not open DM channel with ${SLACK_USER}" >&2
        exit 1
    fi

    slack_post "$channel" "$msg"
    echo "✓ Posted ETF monitor to Slack DM (${DATE_STR})"
}

main
