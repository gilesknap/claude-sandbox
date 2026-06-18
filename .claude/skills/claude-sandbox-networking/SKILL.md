---
name: claude-sandbox-networking
description: >-
  Network egress, firewall, and lateral-movement design for this repo's bwrap
  Claude sandbox. Egress is OPEN by design (ADR 0005); the chosen direction is a
  per-process netns + pasta routing allowlist (ADR 0015, issue #56, refining
  #31). Surface
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

## Standing decision — egress is OPEN (ADR 0005)

`docs/explanations/decisions/0005-network-egress-open.md` (**Accepted**): the
bwrap argv deliberately omits `--unshare-net`, shares the host netns, runs no
per-process egress firewall. Filtering is out of scope *for the core tool* — it
"belongs at the devcontainer boundary." Adding egress control is a **new layered
ADR**, not a reversal of 0005 — written as ADR 0015
(`docs/explanations/decisions/0015-network-egress-jail.md`, **Accepted**,
2026-06-17). Don't flip 0005; 0015 layers on it.

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
holder locks a **routing allowlist** (default → pasta/internet, `blackhole`
RFC1918 except `allow-ip` device IPs from `/etc/claude-sandbox.conf`); then
`exec bwrap … --cap-drop ALL -- claude`, which **inherits** the holder's netns
(bwrap keeps OMITTING `--unshare-net`). Ordering is load-bearing: netns → pasta →
routes locked → Claude.

**DEAD ALTERNATIVE — do not retry:** pasta-creates-the-ns + bwrap-nested-inside.
pasta spawns a pid+mount ns it can't give bwrap a usable `/proc` for → bwrap
aborts on `/proc/<pid>` lookups; remount is EPERM (kernel proc-mount restriction).
Design D flips ns ownership (holder = user+net only → `/proc` valid).

**SECURITY rests on userns ownership, NOT caplessness.** Claude is NOT capless
here — bwrap nests its userns inside the holder's, so `CapBnd` is FULL
(`…1ffffffffff`). Contained because the netns/routes are owned by the holder's
ANCESTOR userns: verified that route del/punch + device-add all EPERM and RFC1918
stays blocked. Consequence: `CapBnd=0` integrity checks (`sandbox-verify.sh`,
`/verify-sandbox`) need a **jail-aware variant** (assert route-immutability, not
CapBnd=0, when the jail is on).

**Structure:** the setup is an inlined `netns_setup()` *inside* `claude-shadow`,
NOT a sourced module — preserves the single-file auditability ADR 0014 / 0008 rest
on. Revisit extraction (its own ADR) only if the net code outgrows the shadow.

**Feasibility — PROVEN unjailed on a real rootless host (2026-06-17):** core
primitive (unprivileged netns create + in-netns routing, no caps) passes;
`pasta` builds a tap given `/dev/net/tun`; **live egress passes** — internet
reachable, non-allowlisted RFC1918 blackholed. Still untested: the Cohort B
device `allow-ip` path (needs a real device IP). Requires `/dev/net/tun` in the
container (`devcontainer.json` runArgs `--device=/dev/net/tun`) — the one hard
container-side dep. Ceiling: a bwrap *escape* could re-plumb — this is a layer
*beneath* the bwrap wall, never stronger. CA broadcast for Claude itself is gone
→ unicast `EPICS_CA_ADDR_LIST`.

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
- **Flipping ADR 0005** instead of adding a new layered ADR.
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
