---
name: claude-sandbox-networking
description: >-
  Network egress, firewall, and lateral-movement design for this repo's bwrap
  Claude sandbox. The per-process egress jail (netns + pasta routing allowlist,
  ADR 0015, issue #56) is ON by default as of 2026-06-18, fail-closed, with a
  CLAUDE_SANDBOX_EGRESS_JAIL=0 escape hatch — overriding ADR 0005's earlier
  open-egress default. Surface
  BEFORE proposing or discussing ANY network change: egress filtering, firewall
  / nftables / iptables / DOCKER-USER, `--unshare-net`, netns / veth, pasta /
  slirp4netns, a CONNECT or SNI proxy, `HTTPS_PROXY` injection, VLAN /
  segmentation, Claude Code's native sandbox `allowedDomains`, or device-access
  networking (EPICS / Channel Access / pvAccess / PMAC).
---

# claude-sandbox-networking

Read before designing or sketching any network-egress change. The live design
is **issue #56**; this skill is the durable context + the guards that stop
agents re-deriving already-rejected options (it has happened).

## Standing decision — the egress jail is ON by default (ADR 0015)

As of **2026-06-18** the per-process egress jail is the **default** posture
(`docs/explanations/decisions/0015-network-egress-jail.md`, **Accepted**). It is
**fail-closed**: if `/dev/net/tun` / pasta / unshare are missing, `claude`
refuses to launch (it does NOT silently fall back to open egress). The escape
hatch is `CLAUDE_SANDBOX_EGRESS_JAIL=0` (env, per session) or `egress-jail = 0`
in `/etc/claude-sandbox.conf` (per host); env wins over conf. Mechanically it's
still a layer *beneath* bwrap (a holder netns), not an in-core firewall — that
part of ADR 0005's reasoning stands.

This **overrides ADR 0005's open-egress *default*** (`0005-network-egress-open.md`,
now "Superseded in part"). 0005's analysis still applies to the `=0` path: with
the jail off the bwrap argv omits `--unshare-net` and shares the host netns, no
per-process firewall — the original open-egress behaviour. So: the default is
jailed; `=0` restores 0005's world. Don't describe egress as "open by default"
anymore, and don't re-add an "opt-in / off by default" framing — that was the
pre-2026-06-18 state.

## Runtime target — rootless Podman (NOT Docker-bridge)

v1 targets **rootless Podman** + Debian/Ubuntu + `remoteUser=root` (rootless
Docker untested). Consequences that invalidate Docker-shaped designs:
- **No host `DOCKER-USER` / iptables** knob for the unprivileged user.
- Outbound is userspace — **pasta** (modern Podman 5+ default) or legacy
  slirp4netns.
- The container likely has **no `CAP_NET_ADMIN`**.
- **Probe caps UNJAILED.** A sandboxed `claude` session reports
  `CapBnd=0000000000000000` (the shadow's `--cap-drop ALL`) and `unshare -rn`
  fails on RO `/proc/self/uid_map` — that's the *jail*, not the container. Run
  the probe from a normal devcontainer terminal.

## Threat & cohorts

- **Threat = lateral movement** (issue #31, now folded into #56): a compromised
  session as a network pivot — RFC1918 probing, internal HTTP, `169.254.169.254`,
  **lab devices with default creds** (PMAC = a *safety* incident). Not exfil
  (bwrap hides creds); the asset is *network reach*.
- **Cohort A** — HTTPS to *named* hosts only. Claude Code's native sandbox
  (`allowedDomains`, an SNI proxy) fits; dual-sandbox mode is issue **#33**.
- **Cohort B (this repo's users)** — lab devices by **bare RFC1918 IP, UDP,
  dynamic ports** (EPICS CA/PVA, PMAC). A hostname allowlist **cannot express
  this**, so native `allowedDomains` is a non-fit. Needs IP/CIDR-level control.

## The approach we've landed on — issue #56 (refines #31 Option C)

Keep `--network=host` (normal shells + CA broadcast untouched); jail **only
Claude** via **Design D** (validated 2026-06-18, `probe-network-jail.sh`): the
shadow creates a user+net ns with `unshare -rn` (a *holder*); **pasta attaches
from OUTSIDE** by PID (`pasta --config-net <holder-pid>`, backgrounds); the
holder locks a **surgical routing allowlist** (see below); then
`exec bwrap … --cap-drop ALL -- claude`, which **inherits** the holder's netns
(bwrap keeps OMITTING `--unshare-net`). Ordering is load-bearing: netns → pasta →
routes locked → Claude.

**SURGICAL policy (v2 — a blanket RFC1918 blackhole is WRONG):** `pasta
--config-net` mirrors the host L3 config into the netns (address, connected
subnet, gateway, resolv.conf DNS). On an all-RFC1918 site (Diamond = all
172.23/16) a blanket blackhole kills DNS, and pasta's connected-subnet route is
more-specific than the blackhole so the whole local /20 stays reachable. So the
holder: `blackhole` 10/8 + 172.16/12 + 192.168/16 + the **connected subnet**,
`unreachable` 169.254/16; then punches back ONLY the **gateway** (/32 on-link),
**DNS resolvers** (/32 via gw, from /etc/resolv.conf — resolution ≠ lateral
movement), and **`allow-ip`** devices (/32 via gw). Blackholes fail-closed;
DNS/device punches fail-soft.

**DEAD ALTERNATIVE — do not retry:** pasta-creates-the-ns + bwrap-nested-inside.
pasta spawns a pid+mount ns it can't give bwrap a usable `/proc` for → bwrap
aborts on `/proc/<pid>` lookups; remount is EPERM (kernel proc-mount restriction).
Design D flips ns ownership (holder = user+net only → `/proc` valid).

**SECURITY rests on userns ownership + effective-cap drop.** Distinguish two cap
sets: `CapEff` (effective, active) is **0** in the jail — bwrap's `--cap-drop ALL`
empties it even in the nested userns — while `CapBnd` (the bounding *ceiling*) is
FULL (`…1ffffffffff`, a nested-userns artifact, vs 0 in the non-jail sandbox).
Route-immutability holds because the netns/routes are owned by the holder's
ANCESTOR userns (caps raised inside Claude's own userns don't reach it): verified
route del/punch + device-add all EPERM, RFC1918 stays blocked.
**verify-sandbox needs NO jail-aware variant** — check 06 asserts `CapEff=0` (not
CapBnd), which holds; the full 18-check battery passes live in a jailed session.
Cap-ceiling diligence is **VERIFIED** (`probe-network-jail-caps.sh`, unjailed,
2026-06-18): the full `CapBnd` ceiling can't be re-raised to weaken another bwrap
protection. Even with a full *effective* cap set gained via a child `unshare
-rUm` userns, remount-rw `/`, bind-over a `--ro-bind` path, and `sethostname` all
`EPERM` — bwrap's locked mounts are immutable from a descendant userns. Inert.

**Structure:** the setup is an inlined `netns_setup()` *inside* `claude-shadow`,
NOT a sourced module — preserves the single-file auditability ADR 0014 / 0008 rest
on. Revisit extraction (its own ADR) only if the net code outgrows the shadow.

**STATUS — IMPLEMENTED + END-TO-END VALIDATED (2026-06-18).** Probe + real
binary both green on a real rootless host: `CLAUDE_SANDBOX_EGRESS_JAIL=1 claude
-p` reaches the API through the jail; route-immutability battery passes; Cohort B
`allow-ip` device path confirmed reachable; same-subnet host blackholed. Lives in
`claude-shadow` (`parse_config` `egress-jail`/`allow-ip` keys, `egress_jail_enabled`
predicate + inlined `netns_holder`/`netns_launch`), **ON by default** — disable
with `CLAUDE_SANDBOX_EGRESS_JAIL=0` (env) or `egress-jail = 0` in
`/etc/claude-sandbox.conf`. Requires `/dev/net/tun` (`devcontainer.json` runArgs
`--device=/dev/net/tun`) — the one hard container-side dep; **fail-closed** if
pasta/unshare/tun missing (`claude` won't launch — the error names the `=0`
escape hatch), never a silent unjailed fallback. Interactive
`claude` + `/verify-sandbox` both confirmed live in a jailed session (18/18 pass
— check 06 asserts `CapEff=0`, which holds). Phase-2 landed on **PR #58** (refs
#56): `install.sh` installs `passt`; CapEff/CapBnd doc corrections; cap-ceiling
diligence probe written + PASSED unjailed (full `CapBnd` inert). STILL PENDING
(see [[network-egress-pasta-jail-wip]]): run `probe-network-jail.sh` in a
**bridge/NAT** container — only `--network=host` tested so far, so the
gateway-collision + nested-pasta paths stay unproven. Ceiling: a bwrap *escape*
could re-plumb — a layer *beneath* the bwrap wall, never stronger. CA broadcast for Claude is gone → unicast
`EPICS_CA_ADDR_LIST`.

**Network-mode-agnostic + intentional blackholing.** Design D builds Claude's
netns INSIDE the container and pasta mirrors the container's OWN connectivity, so
it works whether the container is `--network=host` OR bridge/NAT — same
requirement (`/dev/net/tun`), one install path, one error message. The jail only
RESTRICTS; it cannot grant more reach than the container already has (an
internal/isolated container can't reach a device regardless of the jail). The
`/dev/net/tun` mount and a possible `--network=host`→bridge switch are BOTH
host-`devcontainer.json` edits, so `install` must detect + error with
instructions either way. **Blackholing must be intentional** — CRITICAL in
non-host containers where the egress gateway is itself RFC1918 (or link-local
`169.254.x.x`): blackholing those ranges can sever the default route and kill ALL
egress. `netns_setup()` MUST detect the default next-hop and PIN a more-specific
route to it FIRST: **protect-gateway → blackhole-the-rest → punch allow-ip.**
UNPROVEN until probed in a NON-host (bridge) container: (a) nested pasta
(inner pasta inside an outer-pasta'd container); (b) the gateway-collision
behaviour. **A bridge container = the devcontainer with `--net=host` REMOVED**
(comment `.devcontainer/devcontainer.json` runArgs line `--net=host`; KEEP
`--device=/dev/net/tun`), then rebuild and run `probe-network-jail.sh` from a
normal (unjailed) terminal — revert + rebuild afterwards (the dogfood box needs
host-net for X11 + EPICS CA). Throwaway alternative that leaves the devcontainer
alone: `podman run --rm -it --device=/dev/net/tun -v "$PWD/probe-network-jail.sh:/probe.sh:ro" <devcontainer-image> bash -lc 'apt-get update -qq && apt-get install -y -qq passt bubblewrap iproute2 util-linux && bash /probe.sh'`.
EXPECT: the `[holder]` line shows an RFC1918 gateway (podman `10.88.0.1`, docker
`172.17.0.1`); `PASS internet routed via gateway` + connectivity PASS = proof
that the `$gw/32` on-link route was pinned BEFORE `blackhole 10/8` survived
egress; RFC1918 + same-subnet still blocked. The ONE code-change trigger: holder
logs `no default via/dev` → exits 4 = the dev-only-default edge (a default route
with no `via <gw>`), to be handled then. Only `--network=host` tested so far.

## Refuse / don't re-derive

- Re-proposing the **`HTTPS_PROXY` env-var proxy** (#31 Option D) as *security* —
  a hostile process unsets it / uses a raw socket. It's a guardrail, not a boundary.
- **Docker-bridge / `DOCKER-USER` / `--cap-add NET_ADMIN`-on-the-Claude-container**
  designs — they ignore the rootless-Podman target.
- Claiming a **hostname allowlist** (native `allowedDomains`) covers **Cohort B**
  device traffic — it can't (no bare IP / CIDR / UDP).
- Reading caps **from inside the jail** and concluding the container can't do netns.
- **pasta-creates-the-namespaces with bwrap nested inside** (the dead Plan A) —
  pasta's pid+mount ns gives bwrap an unusable `/proc`; use Design D (holder owns
  a user+net-only ns, pasta attaches from outside).
- Asserting Claude is **capless in the jail** — it is NOT (`CapBnd` full, nested
  userns). Security is ancestor-userns ownership of the netns; don't "fix" the
  full caps or gate jail integrity on `CapBnd=0`.
- **Turning off `--network=host`** (per-container egress allowlist instead of
  per-process) as the DEFAULT. It IS simpler — `CapBnd=0` preserved, no
  `/dev/net/tun`, no holder/pasta-attach (root-in-container owns its own netns,
  locks routes once at init) — but it restricts the **whole** container and
  breaks EPICS CA/PVA broadcast for **all** shells, not just Claude. Rejected as
  default for this EPICS org (Design D breaks broadcast for Claude *only*). It's
  a valid **opt-in posture** for Claude-dedicated / non-EPICS containers, not a
  silent flip of the host-net default. (Keeping host-net is an EPICS-workflow
  choice, NOT a mechanism requirement — see portability note: Design D works in
  non-host containers too.)
- **Rewriting ADR 0005** to say the opposite. Its open-egress *default* is now
  overridden (jail-on-by-default), but that was recorded the right way — a
  "Superseded in part" status note on 0005 + the layered ADR 0015 — leaving 0005's
  analysis intact for the `=0` path. Record future posture changes the same way;
  don't gut 0005.
- Mounting **`docker.sock`** into the Claude container.

## Pointers

| Concern | Where |
|---|---|
| Egress-jail decision (chosen approach) | ADR **0015** `0015-network-egress-jail.md` (Accepted) |
| Live design + feasibility probes | issue **#56** |
| Threat + options A–D (superseded by #56) | issue **#31** (closed) |
| Native dual-sandbox / Cohort A | issue **#33** (open) |
| Egress-open decision / scope | ADRs `0005-network-egress-open`, `0002-credential-isolation-tool` |
| Feasibility probes (embedded in #56, untracked at repo root) | `probe-network-egress.sh` (full pasta egress) + `probe-network-layers.sh` (splits tun-INDEPENDENT core from tun-DEPENDENT forwarder) — run UNJAILED |
| Where `netns_setup()` (holder + pasta attach + route lock) goes — inlined, not yet implemented | `.devcontainer/claude-sandbox/claude-shadow` (bwrap KEEPS omitting `--unshare-net`; the holder owns the netns) |
