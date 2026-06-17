---
name: claude-sandbox-networking
description: >-
  Network egress, firewall, and lateral-movement design decisions for this
  repo's bwrap Claude sandbox. Egress is OPEN by design (ADR 0005); this skill
  records the threat model (issue #31), the cohort / dual-sandbox analysis
  (issue #33), the rootless-podman + guest-no-devcontainer-touch constraints,
  and which approaches are already rejected — so agents don't re-derive them.
  Surface BEFORE proposing or discussing ANY network change: egress filtering,
  firewall / nftables / iptables / DOCKER-USER, `--unshare-net`, netns / veth,
  a CONNECT or SNI proxy, `HTTPS_PROXY` injection, VLAN / network segmentation,
  Claude Code's native sandbox `allowedDomains`, or device-access networking
  (EPICS / Channel Access / pvAccess / PMAC motion controllers).
---

# claude-sandbox-networking

Read this **before** designing or even sketching a network-egress change. The
design space is already well-trodden across ADR 0005, issue #31, and issue #33;
the failure mode this skill prevents is an agent re-proposing an option the repo
already considered and parked. (It happened: a full session re-derived issue
#31's Option C.)

## The standing decision — egress is OPEN, on purpose

`docs/explanations/decisions/0005-network-egress-open.md` (**Accepted**): the
bwrap argv **deliberately omits `--unshare-net`**, shares the host network
namespace, and runs **no** per-process egress firewall. Egress filtering is
**out of scope for this tool** — it "belongs at the devcontainer boundary: run
the container itself behind an egress filter if you need one." Network-identity
disclosure (host IPs, routes, `/etc/resolv.conf`) is **accepted** info
disclosure.

This flows from the tool's scope (ADR 0002): it is a *credential-isolation*
tool. Its strategy is **asset removal** (hide creds so there's nothing to steal
or pivot through), not **exit sealing** (restrict where traffic can go). A
network change does **not** reverse ADR 0005 — per 0005's own text, adding
network sandboxing is a *layered* addition recorded as its **own new ADR**.
Write that ADR; don't silently flip 0005.

## Runtime target — rootless Podman (NOT Docker-bridge semantics)

v1 targets **rootless Podman** + Debian/Ubuntu + `remoteUser=root` (rootless
Docker untested). See `README.md`, `docs/index.md`, `README-CLAUDE.md`
("deliberately exposed" table). Consequences that invalidate Docker-shaped
designs:

- **No host `DOCKER-USER` / iptables knob** available to the unprivileged user.
- Outbound is userspace (**pasta** or **slirp4netns**, depending on Podman
  version) — verify which on the actual target.
- The container almost certainly has **no `CAP_NET_ADMIN`**. Don't assume it.
- "Root inside" is a mapped user with a restricted cap set; veth/netns/nft in
  the container's own netns may simply be `EPERM`.

**Measure, don't guess — and measure UNJAILED.** A sandboxed `claude` session
reports `CapBnd=0000000000000000` because the shadow does `--cap-drop ALL`;
that is the *jail*, not the container. To learn the container's true privilege,
run the probe from a normal devcontainer terminal (only the `claude` binary is
wrapped, not your shell): attempt `unshare -n true`, `ip link add … type veth`,
`nft add table`, and read `/proc/self/status` `CapBnd`. Inside the jail those
all fail by design and tell you nothing about the host container.

## The threat that motivates revisiting — lateral movement (issue #31)

Not exfil (creds are hidden; OSS code has little to steal). The live risk is a
compromised session as a **network pivot**: probing RFC1918, hitting unprotected
internal HTTP (Grafana/Jenkins/k8s API), the cloud metadata IP
`169.254.169.254`, or **lab devices with default creds**. Canonical example:
**Delta Tau / Omron PMAC** motion controllers (embedded Linux, documented
default creds) — a compromised session could alter motion programs. That's a
**safety** incident, not a data breach. Three preconditions must align (routable
to the segment + weak creds + a prompt injection lands); breaking **any one**
helps materially.

## The two cohorts (issue #33) — and ours is the hard one

The native Claude Code sandbox (`sandbox.enabled` + `allowedDomains`) is a
**hostname-aware HTTP(S)/SNI proxy** — hostnames only, **no bare IP, no CIDR,
no ports, no UDP, no broadcast**.

- **Cohort A** — needs only HTTPS to *named* hosts (`api.anthropic.com`,
  github/gitlab, registries, internal websites). Dual-sandbox mode (bwrap +
  native proxy) works and is strictly stronger. Tracked by #33.
- **Cohort B** — talks to **lab hardware**: EPICS IOCs (Channel Access /
  pvAccess: UDP broadcast/unicast search on 5064/5065 + dynamic TCP), PMACs,
  devices addressed by **bare RFC1918 IP with no DNS name**. A hostname
  allowlist **cannot express this**, so the native model is a non-fit and
  `--share-net` stays. **This repo's primary users are Cohort B.** (Note:
  `--cap-drop ALL` does *not* break EPICS — CA/PVA use ordinary unprivileged
  sockets; only raw/L2 tooling is blocked.)

## The constraint stack that ranks the options

A network design for this repo must satisfy **all** of:

1. **ADR 0005** — enforce at the *container boundary*, not inside the tool.
2. **Small audit surface / bash-only** — no ~200-line netns/veth bash, no
   Python (root `CLAUDE.md`, Reversal 1).
3. **Rootless Podman** — no `DOCKER-USER`, likely no `CAP_NET_ADMIN`.
4. **Guest-in without touching the host project's `devcontainer.json`** (the
   constraint surfaced 2026-06; the product value is dropping claude-sandbox
   into an *existing* devcontainer without contaminating it). This rules out
   anything that must be wired at container-creation time inside the guest.
5. **Cohort B device access** — bare-IP / UDP / (ideally) broadcast to
   instruments must keep working.

## Options and verdicts (issue #31 A–D, scored against the stack)

- **A — Infrastructure network segmentation (VLAN/subnet).** Host lands on a
  segment whose route to device networks is an explicit allowlist, enforced by
  the switch/router — outside anything Claude controls. **Recommended.** The
  *only* option that satisfies 1–5 at once: no repo change, no caps, no
  `devcontainer.json` edit, Cohort-B-friendly. **Repo's role is to document the
  required allowlist CIDRs and verify reachability — not to enforce egress.**
- **B — Container-level nftables (`just block-internal-net`).** Needs
  `CAP_NET_ADMIN` + rules wired at launch → fights constraints 3 and 4, and
  in-container rules are removable by a bwrap-escaped root. Viable only where
  infra grants the cap *and* the launch can be controlled.
- **C — `--unshare-net` + veth + host CONNECT proxy.** Rejected by #31 itself
  (audit surface, constraint 2). Also: can't carry Cohort-B bare-IP/UDP; and
  rootless has no privileged "host side" for the veth. **Do not re-propose
  without re-justifying against #31-C and Reversal 1.** (An agent already did.)
- **D — `HTTPS_PROXY` injection only.** A guardrail for *cooperating* tools;
  a hostile process unsets the var or opens a raw socket. **Not a security
  boundary.** Don't present it as one.
- **#33 dual-sandbox native proxy.** Cohort A only; cannot express device
  traffic. Good *defence-in-depth* for HTTPS-only devcontainers, **not** a
  solution for Cohort B.

## Channel Access reconciliation (if any isolation is ever adopted)

Any netns/segment isolation kills CA **broadcast discovery** (the reason
`--network=host` is used). Reconcile by pinning `EPICS_CA_ADDR_LIST` to the
explicit device IPs + `EPICS_CA_AUTO_ADDR_LIST=NO` (unicast). Broadcast support
is **out of scope** unless explicitly funded.

## Refuse / don't re-derive

- Re-proposing **Option C** (`--unshare-net`+veth) or **Option D** (env proxy)
  as *security* without engaging #31's existing verdicts.
- **Docker-bridge / `DOCKER-USER` / `--cap-add NET_ADMIN`-on-the-Claude-
  container** designs that ignore the rootless-Podman target.
- Anything that requires **editing the guest's `devcontainer.json`** /
  container-creation args (constraint 4) — unless the user opts in for the
  dogfood/promote path specifically.
- Claiming a **hostname allowlist** covers Cohort B device traffic — it can't.
- **Flipping ADR 0005** instead of adding a new layered ADR.
- Mounting **`docker.sock`** into the Claude container (hands over the host).

## Pointers

| Concern | Where |
|---|---|
| Egress-open decision | `docs/explanations/decisions/0005-network-egress-open.md` |
| Scope (credential isolation) | `docs/explanations/decisions/0002-credential-isolation-tool.md` |
| Lateral-movement threat + options A–D | issue **#31** (open) |
| Dual-sandbox / cohort analysis | issue **#33** (open) |
| Threat model + cohorts + "deliberately exposed" | `README-CLAUDE.md` |
| bwrap argv (where `--unshare-net` would go, but doesn't) | `.devcontainer/claude-sandbox/claude-shadow` |
