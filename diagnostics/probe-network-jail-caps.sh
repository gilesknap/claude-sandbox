#!/usr/bin/env bash
# Cap-ceiling diligence probe (issue #56 / ADR 0015 phase-2 item 1).
#
# The egress jail nests bwrap inside an `unshare -rn` holder. A side effect of
# that nested userns is that bwrap's process reports a FULL capability BOUNDING
# set (CapBnd=…1ffffffffff) instead of the 0 it shows in the non-jail sandbox —
# while its EFFECTIVE set (CapEff) is still emptied to 0 by `--cap-drop ALL`.
# verify-sandbox check 06 asserts CapEff=0 (which holds), so no jail-aware
# verify variant is needed. THIS probe closes the residual question the skill
# flags: can that higher bounding *ceiling* be re-raised inside Claude's own
# userns to weaken a bwrap protection that does NOT depend on CapEff — namely
# the read-only filesystem (`--ro-bind / /`, locked-mount semantics)?
#
# A process can only raise into CapEff what is in CapPrm (permitted); cap-drop
# empties both, and NO_NEW_PRIVS forbids regaining them via exec. The one way
# back to a full cap set is to create a NEW (child) userns — where the creator
# is namespace-root with all caps. The kernel's locked-mount rule is the wall
# we are testing: mounts a userns-owner locked stay immutable from any
# DESCENDANT userns, even one whose CapEff is full. If that holds, the full
# CapBnd ceiling is inert for the filesystem too, and the jail is safe to
# recommend broadly. If any assertion FAILS, it's a real finding — mitigate
# before recommending the jail.
#
# This mirrors probe-network-jail.sh's holder+bwrap nesting EXACTLY (so the cap
# sets match the live jail) but drops pasta/tun: connectivity is irrelevant to
# a filesystem/capability question, so this probe needs neither.
#
# ► RUN ME UNJAILED ◄  (a normal devcontainer terminal, not a sandboxed `claude`).
#
# Usage: ./probe-network-jail-caps.sh
set -uo pipefail

if [ "${IS_SANDBOX:-}" = 1 ] || \
   [ "$(awk '/CapBnd/{print $2}' /proc/self/status)" = 0000000000000000 ]; then
  echo "Inside the bwrap jail — run me from a normal terminal."; exit 2
fi
command -v bwrap   >/dev/null || { echo "bwrap not found — sudo apt-get install bubblewrap"; exit 2; }
command -v unshare >/dev/null || { echo "unshare not found — install util-linux"; exit 2; }

INNER=$(mktemp); HOLD=$(mktemp); export INNER
trap 'rm -f "$INNER" "$HOLD"' EXIT

# INNER — Claude's vantage inside the jailed bwrap. CapEff is 0, CapBnd is full.
# Every attempt below must be denied; the locked --ro-bind / / must survive even
# an attacker who reaches for caps via a child userns.
cat > "$INNER" <<'EOF'
set -u
eff=$(awk '/CapEff/{print $2}' /proc/self/status)
bnd=$(awk '/CapBnd/{print $2}' /proc/self/status)
echo "INFO  CapEff=$eff (0 expected — dropped) CapBnd=$bnd (full expected — nested-userns ceiling)"
[ "$eff" = 0000000000000000 ] && echo "PASS  effective caps are empty (CapEff=0)" \
                              || echo "WARN  CapEff is non-zero: $eff"

probe="/etc/.caps-probe.$$"
echo "  --- direct attempts (CapEff=0, no child userns) ---"
mount -o remount,rw / 2>/dev/null && echo "FAIL  SECURITY: remounted / rw" \
                                  || echo "PASS  cannot remount / rw (EPERM)"
( : > "$probe" ) 2>/dev/null && { echo "FAIL  SECURITY: wrote to ro /etc"; rm -f "$probe"; } \
                             || echo "PASS  / read-only — write to /etc denied"
td=$(mktemp -d 2>/dev/null) && mount --bind "$td" /etc 2>/dev/null \
    && echo "FAIL  SECURITY: bind-mounted over the ro /etc" \
    || echo "PASS  cannot bind-mount over /etc (EPERM)"
hostname caps-probe 2>/dev/null && echo "FAIL  SECURITY: sethostname succeeded (CAP_SYS_ADMIN active)" \
                                || echo "PASS  cannot sethostname (no effective CAP_SYS_ADMIN)"

echo "  --- escalation: full caps via a CHILD userns, then defeat the ro-bind ---"
# unshare -r maps us to root in a NEW userns → full CapEff *there*. The bwrap
# mounts are locked by an ANCESTOR userns, so they must stay immutable anyway.
if unshare -rUm true 2>/dev/null; then
  unshare -rUm bash -c '
    e=$(awk "/CapEff/{print \$2}" /proc/self/status)
    echo "    [child-userns] CapEff=$e (full inside the child userns)"
    mount -o remount,rw / 2>/dev/null && echo "FAIL  SECURITY: remounted locked / rw from child userns" \
                                      || echo "PASS  locked / survives child-userns CAP_SYS_ADMIN (EPERM)"
    ( : > "/etc/.caps-probe2.$$" ) 2>/dev/null \
        && { echo "FAIL  SECURITY: wrote /etc from child userns"; rm -f "/etc/.caps-probe2.$$"; } \
        || echo "PASS  / stays read-only even with child-userns caps"
    td2=$(mktemp -d 2>/dev/null) && mount --bind "$td2" /usr 2>/dev/null \
        && echo "FAIL  SECURITY: bind-mounted over ro /usr from child userns" \
        || echo "PASS  cannot bind over locked /usr from child userns (EPERM)"
  '
else
  echo "PASS  cannot even create a child userns (unshare -r EPERM) — escalation route closed"
fi
EOF

# HOLDER — the jail's user+net-ns owner (lo only; no pasta, no connectivity
# needed). Mirrors netns_holder's bwrap launch so the cap sets are identical.
cat > "$HOLD" <<'EOF'
set -u
ip link set lo up 2>/dev/null || true
exec bwrap --ro-bind / / --dev /dev --unshare-pid --cap-drop ALL -- bash "$INNER"
EOF

echo "Reproducing the jail's userns nesting (unshare -rn holder → bwrap --cap-drop ALL)…"
unshare -rn bash "$HOLD" &
HOLDER=$!
wait "$HOLDER"; rc=$?
[ "$rc" -eq 0 ] && echo "Done. If all PASS: full CapBnd is inert — the locked ro-bind holds against the ceiling." \
                || echo "FAIL  holder exited rc=$rc"
exit "$rc"
