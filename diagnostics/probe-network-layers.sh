#!/usr/bin/env bash
# Layered feasibility probe — separates the tun-INDEPENDENT core (unprivileged
# netns + in-netns routing) from the tun-DEPENDENT forwarder step, so you can
# see which half each result belongs to. Companion to probe-network-jail.sh
# (the full pasta egress test). Issue #56 / refines #31 Option C.
#
# ► RUN ME UNJAILED ◄  (normal terminal, not a sandboxed `claude`).
set -uo pipefail
P(){ echo "  [PASS] $*"; }
F(){ echo "  [FAIL] $*"; }
I(){ echo "  [info] $*"; }

capbnd=$(awk '/CapBnd/{print $2}' /proc/self/status 2>/dev/null)
if [ "${IS_SANDBOX:-}" = 1 ] || [ "$capbnd" = 0000000000000000 ]; then
  echo "Inside the bwrap jail (CapBnd=$capbnd) — run me from a normal terminal."; exit 2
fi

echo "Layer 1 — CORE (no /dev/net/tun): unprivileged netns + in-netns routing"
if unshare -rn bash -c '
      set -e
      ip link set lo up
      ip route add blackhole 10.0.0.0/8
      ip route add blackhole 172.16.0.0/12
      ip route add blackhole 192.168.0.0/16
      ip route add unreachable 169.254.0.0/16
      ip route add 10.1.2.3 dev lo            # more-specific allow over a blackhole
      ip route show | grep -q blackhole
   ' 2>/tmp/pl.err; then
  P "userns+netns create + blackhole/allow routing (CAP_NET_ADMIN over own netns)"
else
  F "core failed -> $(tr -d '\n' </tmp/pl.err)"
  I "likely the unprivileged-userns restriction; check kernel.apparmor_restrict_unprivileged_userns"
  rm -f /tmp/pl.err; exit 1
fi
rm -f /tmp/pl.err

echo "Layer 2 — FORWARDER (needs /dev/net/tun): can pasta build a tap?"
if [ -e /dev/net/tun ]; then
  P "/dev/net/tun present"
else
  F "/dev/net/tun MISSING — add \"--device=/dev/net/tun\" to devcontainer runArgs + rebuild"
  I "pasta and slirp4netns are both TAP-based; neither works without this node"
  exit 1
fi
if command -v pasta >/dev/null; then
  if pasta --config-net -- true 2>/tmp/pp.err; then
    P "pasta set up a namespace + tap"
  else
    F "pasta -> $(tr -d '\n' </tmp/pp.err | cut -c1-160)"
    rm -f /tmp/pp.err
    exit 1
  fi
  rm -f /tmp/pp.err
else
  I "pasta not installed (sudo apt-get install passt) — skipped"
fi

echo "Done. CORE pass = netns/routing design feasible; FORWARDER pass = pasta path clear."
