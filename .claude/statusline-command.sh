#!/usr/bin/env bash
# Claude Code status line: model + git branch + context & rate-limit usage.
#
# Reads Claude's JSON status payload from stdin and prints a colored
# one-liner: username · model · cwd · git branch · ctx · 5h/7d windows.
# Uses jq for JSON parsing so no python is needed — works fine inside the
# bwrap sandbox where the host's python is masked off. If jq is missing,
# falls through to a bash-only degraded line.

input=$(cat)

degraded_line() {
    local username cwd short_cwd
    username=$(whoami 2>/dev/null || echo "?")
    cwd=$(printf '%s' "$input" | sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -z "$cwd" ] && cwd="$PWD"
    short_cwd="${cwd/#$HOME/~}"
    printf "\033[0;35m%s\033[0m  \033[0;33m%s\033[0m  \033[2;37m(no jq — degraded statusline)\033[0m" \
        "$username" "$short_cwd"
}

command -v jq >/dev/null 2>&1 || { degraded_line; exit 0; }

# Pick a color for a usage percentage: green <50, yellow <80, red otherwise.
# Strips any decimal part first; an empty/non-numeric value falls to green.
pct_color() {
    local p=${1%.*}
    if [ "$p" -ge 80 ] 2>/dev/null; then printf '\033[1;31m'
    elif [ "$p" -ge 50 ] 2>/dev/null; then printf '\033[0;33m'
    else printf '\033[0;32m'; fi
}

# Compact "resets in" hint from a reset timestamp, e.g. "2h13m" / "3d4h".
# Accepts a unix epoch or an ISO-8601 string; anything unparseable yields
# nothing (the hint is simply omitted rather than printing noise).
reset_in() {
    local target=$1 now diff d h m
    [ -z "$target" ] && return
    case "$target" in
        *[!0-9]*) target=$(date -d "$target" +%s 2>/dev/null) || return ;;
    esac
    [ -z "$target" ] && return
    now=$(date +%s)
    diff=$((target - now))
    [ "$diff" -le 0 ] && { printf 'now'; return; }
    d=$((diff / 86400)); h=$(((diff % 86400) / 3600)); m=$(((diff % 3600) / 60))
    if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
    else printf '%dm' "$m"; fi
}

# Single jq pass emits unit-separator () delimited fields so a
# malformed value can't bleed across columns. We can't use \t: `read`
# treats tab as IFS-whitespace and collapses runs of it, so an empty
# field (e.g. absent .effort.level) would silently shift every later
# column. \x1f is non-whitespace, so empty fields are preserved.
# `// ""` yields empty strings rather than the literal "null".
IFS=$'\x1f' read -r model effort cwd used h_pct h_reset w_pct w_reset < <(
    printf '%s' "$input" | jq -r '
        [
            (.model.display_name // "unknown model"),
            (.effort.level // ""),
            (.workspace.current_dir // .cwd // ""),
            (.context_window.used_percentage // "" | tostring),
            (.rate_limits.five_hour.used_percentage // "" | tostring),
            (.rate_limits.five_hour.resets_at // "" | tostring),
            (.rate_limits.seven_day.used_percentage // "" | tostring),
            (.rate_limits.seven_day.resets_at // "" | tostring)
        ] | join("")
    ' 2>/dev/null
) || { degraded_line; exit 0; }

if [ -z "$model" ]; then
    degraded_line
    exit 0
fi

short_cwd="${cwd/#$HOME/~}"
username=$(whoami 2>/dev/null || echo "unknown")

# The status payload has no branch field, so derive it from cwd. Use the
# plumbing form (--no-optional-locks, so a read-only status line never
# touches the index) and fall back to a short SHA on a detached HEAD;
# a non-repo cwd yields an empty branch and the column is omitted.
branch=$(git --no-optional-locks -C "${cwd:-$PWD}" symbolic-ref --quiet --short HEAD 2>/dev/null \
         || git --no-optional-locks -C "${cwd:-$PWD}" rev-parse --short HEAD 2>/dev/null)

# Effort level is only present for models that support it; suffix it to
# the model column (e.g. "Opus 4.8 · high") when available.
if [ -n "$effort" ]; then
    model="$model · $effort"
fi

# username · model
printf "\033[0;35m%s\033[0m  \033[0;36m%s\033[0m" \
    "$username" "$model"

# context window usage — promoted high (one of the most-watched signals).
# Green/yellow/red gradient by % used.
if [ -n "$used" ]; then
    printf "  %sctx:%.0f%%\033[0m" "$(pct_color "$used")" "$used"
else
    printf "  \033[2mctx:new\033[0m"
fi

# cwd, then branch in "path branch" style — single space, no prefix, à la the
# zsh dst theme — with a trailing ! when the working tree is dirty (any staged,
# unstaged, or untracked change).
printf "  \033[0;33m%s\033[0m" "$short_cwd"
if [ -n "$branch" ]; then
    dirty=""
    [ -n "$(git --no-optional-locks -C "${cwd:-$PWD}" status --porcelain 2>/dev/null)" ] && dirty="!"
    printf " \033[0;35m%s%s\033[0m" "$branch" "$dirty"
fi

# 5-hour usage window
if [ -n "$h_pct" ]; then
    printf "  %s5h:%.0f%%\033[0m" "$(pct_color "$h_pct")" "$h_pct"
    r=$(reset_in "$h_reset"); [ -n "$r" ] && printf "\033[2m(%s)\033[0m" "$r"
fi

# 7-day usage window
if [ -n "$w_pct" ]; then
    printf "  %s7d:%.0f%%\033[0m" "$(pct_color "$w_pct")" "$w_pct"
    r=$(reset_in "$w_reset"); [ -n "$r" ] && printf "\033[2m(%s)\033[0m" "$r"
fi
