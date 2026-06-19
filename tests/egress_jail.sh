#!/usr/bin/env bash
# Egress-jail netns enforcement test (ADR 0015, issue #56 / #63 test-gap).
#
# The jail's ACTUAL enforcement — netns_holder's routing allowlist: blackhole
# RFC1918 + CGNAT + every connected subnet, punch back only the gateway / DNS /
# allow-ip /32s, IPv6 dropped (pasta --ipv4-only), and fail-CLOSED if any
# load-bearing `ip route` add fails — had ZERO automated coverage. verify-sandbox
# checks 19/20 need a LIVE jailed `claude` (manual); smoke.sh never enters the
# netns. A regression that drops a blackhole or breaks fail-closed would stay
# CI-green. This test exercises netns_holder's routing in a THROWAWAY netns so
# such a regression fails CI.
#
# Strategy: drive the REAL netns_holder function (sourced from claude-shadow,
# not a re-implementation, so the test can't drift from the shipped logic) inside
# an `unshare -rn` user+net namespace. We synthesise a default route + a
# connected subnet on a dummy interface instead of attaching pasta, so the
# routing-allowlist + fail-closed assertions need only CAP_NET_ADMIN — NOT
# pasta/tun. A separate pasta-backed live leg runs only when pasta + /dev/net/tun
# are also present; absence of any prerequisite SKIPs cleanly (clear message,
# exit 0) so CI never flakes.
#
#   bash tests/egress_jail.sh
#
# Exit: 0 = all assertions passed OR cleanly skipped; 1 = a real assertion failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHADOW="$REPO_ROOT/.devcontainer/claude-sandbox/claude-shadow"

# Shared PASS/FAIL counters + finish().
# shellcheck source=lib.sh
source "$REPO_ROOT/tests/lib.sh"

# skip MSG — print a clear, non-failing skip notice and exit 0 so a runner that
# can't grant the caps logs WHAT was skipped (no silent no-op, no pretend
# coverage) and CI stays green.
skip() {
    echo "SKIP: egress_jail — $1" >&2
    echo "egress_jail: skipped (no netns/CAP_NET_ADMIN here — caps required)"
    exit 0
}

[ -r "$SHADOW" ] || skip "claude-shadow not found at $SHADOW"
command -v unshare >/dev/null 2>&1 || skip "unshare (util-linux) not available"
command -v ip      >/dev/null 2>&1 || skip "ip (iproute2) not available"

# Capability gate: can we create a user+net+MOUNT namespace, program a blackhole
# route, AND bind a file over /etc/resolv.conf in it? These are the exact
# primitives netns_holder + this test rely on (the holder reads /etc/resolv.conf
# directly, so the test must bind a fixture over it — which needs the mount ns
# from `-m`). If any fails (locked-down kernel, read-only /proc/self/uid_map, no
# CAP_NET_ADMIN, restricted unprivileged userns) we SKIP.
if ! unshare -rnm bash -c '
        ip link set lo up &&
        ip route replace blackhole 10.0.0.0/8 &&
        ip route show table all 2>/dev/null | grep -q blackhole &&
        t="$(mktemp)" && printf "nameserver 203.0.113.1\n" > "$t" &&
        mount --bind "$t" /etc/resolv.conf
     ' >/dev/null 2>&1; then
    skip "cannot create a user+net+mount namespace with route programming + bind mount"
fi

echo "egress_jail: caps present — exercising netns_holder routing"

# ---------------------------------------------------------------------------
# Pull netns_holder (and its helpers jail_fail / wait_for / route_field) into
# scope WITHOUT running the launch body. CLAUDE_SHADOW_SOURCE_ONLY=1 makes
# claude-shadow define-and-return. JAIL_DNS_FWD is defined by the shadow too.
# ---------------------------------------------------------------------------
CLAUDE_SHADOW_SOURCE_ONLY=1
export CLAUDE_SHADOW_SOURCE_ONLY
# shellcheck source=/dev/null
source "$SHADOW"

for fn in netns_holder jail_fail wait_for route_field; do
    if ! declare -F "$fn" >/dev/null; then
        fail "claude-shadow did not define $fn (source-only contract broke)"
        finish "egress_jail"; exit $?
    fi
done

# ===========================================================================
# Leg 1 — routing allowlist + fail-closed, driven through the REAL
# netns_holder in a dummy-backed netns (no pasta, CAP_NET_ADMIN only).
#
# Each invocation: unshare -rn → bring up a dummy NIC with a synthetic
# connected subnet + default gateway (standing in for what pasta --config-net
# would mirror) → export the env netns_holder expects → call netns_holder with
# a probe command as "$@". netns_holder programs the allowlist, then exec's the
# probe, which dumps the resulting route table for the parent to assert on.
# ===========================================================================

RUNDIR="$(mktemp -d)"
register_cleanup "$RUNDIR"

# A synthetic topology that looks like a real LAN: gateway + a connected /24,
# none of which overlap the RFC1918/CGNAT literals so we can tell the
# connected-subnet blackhole apart from the fixed ones.
JAIL_TEST_GW="198.51.100.1"          # RFC5737 TEST-NET-2 (non-routable)
JAIL_TEST_SUBNET="198.51.100.0/24"
JAIL_TEST_ADDR="198.51.100.50/24"
JAIL_TEST_DNS="198.51.100.53"        # routable (non-loopback) resolver
JAIL_TEST_ALLOWIP="203.0.113.7"      # RFC5737 TEST-NET-3 allow-ip device

# run_holder OUTFILE [PRE] — run netns_holder in a fresh netns. The holder
# programs the allowlist then exec's a dumper that writes the final IPv4 route
# table to OUTFILE. PRE is optional shell run INSIDE the netns BEFORE the holder
# (used by the fail-closed leg to sabotage `ip`). Returns the holder's rc.
run_holder() {
    local outfile="$1" pre="${2:-}"
    : > "$outfile"
    # The body runs inside `unshare -rn` as a fresh `bash -c`, so it must
    # re-source the shadow to get netns_holder, and re-export the env the holder
    # reads. CLAUDE_JAIL_READY is pre-touched so the holder's readiness wait
    # returns immediately (we are not driving the real pasta handshake here).
    # TADDR carries the connected /24; the holder ENUMERATES the resulting
    # scope-link route itself (as it would from pasta --config-net), so there is
    # no need to pass the subnet literal in — that's the point of leg1.
    unshare -rnm env \
        SHADOW="$SHADOW" OUTFILE="$outfile" PRE="$pre" \
        TGW="$JAIL_TEST_GW" TADDR="$JAIL_TEST_ADDR" \
        TDNS="$JAIL_TEST_DNS" TALLOW="$JAIL_TEST_ALLOWIP" RUNDIR="$RUNDIR" \
        bash -c '
            set -uo pipefail
            # Optional sabotage hook (fail-closed leg) runs first.
            [ -n "${PRE:-}" ] && eval "$PRE"

            # Synthesise the L3 config pasta --config-net would have mirrored:
            # a dummy NIC carrying the connected subnet + a default via the gw.
            ip link set lo up
            ip link add jailtest0 type dummy 2>/dev/null || true
            ip link set jailtest0 up
            ip addr add "$TADDR" dev jailtest0
            ip route replace default via "$TGW" dev jailtest0

            # resolv.conf the holder reads for DNS punch-back. A routable
            # resolver so the holder routes a /32 for it (loopback is skipped).
            printf "nameserver %s\n" "$TDNS" > "$RUNDIR/resolv.conf"

            # netns_holder reads /etc/resolv.conf directly; bind our fixture
            # over it for THIS netns only (the mount ns is unshared by the -m in
            # `unshare -rnm`, so this never touches the host resolv.conf).
            mount --bind "$RUNDIR/resolv.conf" /etc/resolv.conf \
                || echo "egress_jail: WARN — could not bind fixture resolv.conf; DNS leg may misfire" >&2

            # Env the holder consumes.
            export CLAUDE_JAIL_READY="$RUNDIR/ready"
            : > "$CLAUDE_JAIL_READY"
            export CLAUDE_SANDBOX_ALLOW_IP="$TALLOW"

            export CLAUDE_SHADOW_SOURCE_ONLY=1
            # shellcheck source=/dev/null
            source "$SHADOW"

            # Drive the REAL holder; the dumper is its exec target ("$@").
            netns_holder bash -c "ip -4 route show table all > \"$OUTFILE\" 2>&1"
        '
}

ROUTES="$RUNDIR/routes.txt"
if run_holder "$ROUTES"; then
    pass   # holder completed (fail-closed leg below asserts the inverse)
else
    fail "leg1 — netns_holder aborted on a valid topology (rc=$?)"
fi

# Assertions over the programmed route table. has/blocked are grep predicates
# tolerant of `ip route` formatting (subnet may print without an explicit /N
# only for /32s; our literals are all non-/32 except the punched ones).
routes="$(cat "$ROUTES" 2>/dev/null || true)"

# Echo the table netns_holder actually programmed, so a CI failure shows the
# real route forms instead of a bare assertion name (no guessing from logs).
echo "egress_jail: leg1 programmed IPv4 routes —" >&2
printf '%s\n' "$routes" | sed 's/^/  | /' >&2

has() { printf '%s\n' "$routes" | grep -Eq "$1"; }

# Default route present (restored after the blackholes).
if has "^default via ${JAIL_TEST_GW//./\\.} "; then pass
else fail "leg1 — no default route via gateway after allowlist (fail-OPEN risk)"; fi

# RFC1918 + CGNAT literals blackholed.
for net in '10\.0\.0\.0/8' '172\.16\.0\.0/12' '192\.168\.0\.0/16' '100\.64\.0\.0/10'; do
    if has "^blackhole ${net}"; then pass
    else fail "leg1 — ${net//\\/} not blackholed (lateral-movement leak)"; fi
done

# Link-local marked unreachable.
if has "^unreachable 169\.254\.0\.0/16"; then pass
else fail "leg1 — 169.254.0.0/16 not unreachable"; fi

# The CONNECTED subnet pasta mirrored is blackholed (longest-prefix-match would
# otherwise leave the whole local LAN reachable past the RFC1918 blackholes).
if has "^blackhole ${JAIL_TEST_SUBNET//./\\.}"; then pass
else fail "leg1 — connected subnet $JAIL_TEST_SUBNET not blackholed (same-LAN leak)"; fi

# Gateway stays reachable (pinned on-link as a /32).
if has "^${JAIL_TEST_GW//./\\.}(/32)? dev jailtest0"; then pass
else fail "leg1 — gateway $JAIL_TEST_GW not pinned on-link (jail would have no egress)"; fi

# DNS resolver punched back as a /32 via the gateway. This resolver sits ON the
# connected subnet, so the assertion proves an allowed host stays reachable past
# the connected-subnet blackhole (the /32 punch outweighs the /24 blackhole).
if has "^${JAIL_TEST_DNS//./\\.}(/32)? via ${JAIL_TEST_GW//./\\.}"; then pass
else fail "leg1 — DNS resolver $JAIL_TEST_DNS not punched back via gateway"; fi

# allow-ip device punched back as a /32 via the gateway.
if has "^${JAIL_TEST_ALLOWIP//./\\.}(/32)? via ${JAIL_TEST_GW//./\\.}"; then pass
else fail "leg1 — allow-ip device $JAIL_TEST_ALLOWIP not reachable via gateway"; fi

# DNS forwarder /32 (issue #60) punched back. JAIL_DNS_FWD comes from the shadow.
if has "^${JAIL_DNS_FWD//./\\.}(/32)? via ${JAIL_TEST_GW//./\\.}"; then pass
else fail "leg1 — DNS forwarder $JAIL_DNS_FWD not punched back via gateway"; fi

# ===========================================================================
# Leg 2 — FAIL CLOSED. Sabotage `ip` for the holder so a load-bearing
# `ip route replace blackhole` fails; netns_holder MUST abort (jail_fail) and
# NEVER reach the exec — i.e. the dumper must NOT run, OUTFILE stays empty, and
# the holder's rc is non-zero. A fail-OPEN regression (dropping a `|| jail_fail`
# or losing `set -e`) would let the holder exec anyway, which this catches.
# ===========================================================================

FC_OUT="$RUNDIR/failclosed.txt"
# Shadow `ip` with a wrapper that fails specifically on `route replace blackhole`
# (the load-bearing step) but lets every OTHER ip call through, so the topology
# still builds and the holder reaches the blackhole step before failing. The
# wrapper dir is prepended to PATH inside the netns.
FC_PRE='
    mkdir -p "$RUNDIR/fcbin"
    REAL_IP="$(command -v ip)"
    cat > "$RUNDIR/fcbin/ip" <<FCEOF
#!/usr/bin/env bash
# Fail-closed sabotage: break the load-bearing blackhole step only; pass every
# other ip call through so the topology still builds and the holder reaches it.
case "\$*" in
  *"route replace blackhole"*) exit 1 ;;
esac
exec "$REAL_IP" "\$@"
FCEOF
    chmod +x "$RUNDIR/fcbin/ip"
    export PATH="$RUNDIR/fcbin:$PATH"
'

if run_holder "$FC_OUT" "$FC_PRE"; then
    fail "leg2 — netns_holder did NOT fail closed: it exec'd despite a forced blackhole-route failure (fail-OPEN)"
else
    pass  # non-zero rc — holder aborted as required
fi

# Defence in depth: the dumper must never have run, so OUTFILE stays empty.
if [ -s "$FC_OUT" ]; then
    fail "leg2 — holder exec'd the launch target despite the route failure (route table was dumped → fail-OPEN)"
else
    pass
fi

# ===========================================================================
# Leg 3 (best-effort) — live pasta-backed netns: assert NO IPv6 (pasta
# --ipv4-only) and a working default route. Runs ONLY when pasta + /dev/net/tun
# are present; otherwise logs a sub-skip (the core enforcement above already
# ran). Reuses the diagnostics probe's pasta wiring.
# ===========================================================================

if command -v pasta >/dev/null 2>&1 && [ -e /dev/net/tun ]; then
    echo "egress_jail: leg3 — pasta + /dev/net/tun present, running live IPv6-absence check"
    L3_OUT="$RUNDIR/leg3.txt"; : > "$L3_OUT"
    READY="$RUNDIR/leg3.ready"; rm -f "$READY"
    PASTA_LOG="$RUNDIR/leg3.pasta.log"

    # Holder: bring up lo, wait for pasta-ready, then dump v6 global addrs +
    # default route. We do NOT re-run the full allowlist here (leg1 covered it);
    # this leg only proves the netns has no IPv6 and a default route after pasta.
    unshare -rn env READY="$READY" OUT="$L3_OUT" bash -c '
        set -u
        ip link set lo up
        for _ in $(seq 1 200); do [ -f "$READY" ] && break; sleep 0.05; done
        {
            echo "V6GLOBAL:$(ip -6 addr show scope global 2>/dev/null | awk "/inet6/{print \$2}" | tr "\n" " ")"
            echo "DEFAULT:$(ip route show default 2>/dev/null | head -n1)"
        } > "$OUT"
    ' &
    HOLDER=$!
    for _ in $(seq 1 200); do [ -e "/proc/$HOLDER/ns/net" ] && break; sleep 0.05; done
    if [ -e "/proc/$HOLDER/ns/net" ] \
       && pasta --config-net --ipv4-only --dns-forward "$JAIL_DNS_FWD" \
                --quiet --log-file "$PASTA_LOG" "$HOLDER" 2>>"$PASTA_LOG"; then
        : > "$READY"
        wait "$HOLDER" || true
        l3="$(cat "$L3_OUT" 2>/dev/null || true)"
        # No global IPv6 address ⇒ no v6 address family to pivot through.
        if printf '%s\n' "$l3" | grep -q '^V6GLOBAL: *$'; then pass
        else fail "leg3 — netns has a global IPv6 address (pasta --ipv4-only breach): $l3"; fi
        # Default route exists after pasta --config-net.
        if printf '%s\n' "$l3" | grep -q '^DEFAULT:default '; then pass
        else fail "leg3 — no default route after pasta --config-net: $l3"; fi
    else
        kill "$HOLDER" 2>/dev/null || true
        echo "SKIP(leg3): pasta could not attach a netns here (see $PASTA_LOG) — IPv6/default-route leg not run" >&2
    fi
else
    echo "SKIP(leg3): pasta and/or /dev/net/tun absent — live IPv6/default-route leg not run (core enforcement above DID run)" >&2
fi

finish "egress_jail"
