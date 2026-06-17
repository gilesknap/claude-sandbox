---
name: claude-sandbox-networking
description: >-
  Network egress, firewall, and lateral-movement design for this repo's bwrap
  Claude sandbox. Egress is OPEN by design (ADR 0005); the chosen direction is a
  per-process netns + pasta routing allowlist (issue #56, refining #31). Surface
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
ADR**, not a reversal of 0005. Write that ADR; don't silently flip it.

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
Claude**: `bwrap --unshare-net` → Claude in its own netns, bridged out by
**pasta** (no container caps, no host firewall), with a **routing allowlist**:
default route → pasta (internet), `blackhole` RFC1918 except the `allow-ip`
device IPs from `/etc/claude-sandbox.conf`. Claude is capless so it can't edit
the routes; the shadow configures the netns before handing off.

**Feasibility:** the core primitive (unprivileged netns create + in-netns
routing, no caps) is **confirmed on a real rootless host** (probe 5/0). Live
egress through pasta is pending verification. Possibly guest-friendly (lives in
shadow + `install.sh`, maybe no `devcontainer.json` change). Ceiling: a bwrap
*escape* could re-plumb — this is a layer *beneath* the bwrap wall, never
stronger. CA broadcast for Claude itself is gone → unicast `EPICS_CA_ADDR_LIST`.

## Refuse / don't re-derive

- Re-proposing the **`HTTPS_PROXY` env-var proxy** (#31 Option D) as *security* —
  a hostile process unsets it / uses a raw socket. It's a guardrail, not a boundary.
- **Docker-bridge / `DOCKER-USER` / `--cap-add NET_ADMIN`-on-the-Claude-container**
  designs — they ignore the rootless-Podman target.
- Claiming a **hostname allowlist** (native `allowedDomains`) covers **Cohort B**
  device traffic — it can't (no bare IP / CIDR / UDP).
- Reading caps **from inside the jail** and concluding the container can't do netns.
- **Flipping ADR 0005** instead of adding a new layered ADR.
- Mounting **`docker.sock`** into the Claude container.

## Pointers

| Concern | Where |
|---|---|
| Live design (chosen approach) | issue **#56** |
| Threat + options A–D (superseded by #56) | issue **#31** (closed) |
| Native dual-sandbox / Cohort A | issue **#33** (open) |
| Egress-open decision / scope | ADRs `0005-network-egress-open`, `0002-credential-isolation-tool` |
| Feasibility probe (lives in #56, not committed) | `probe-network-egress.sh` (run UNJAILED) |
| Where `--unshare-net` would go (but doesn't, today) | `.devcontainer/claude-sandbox/claude-shadow` |
