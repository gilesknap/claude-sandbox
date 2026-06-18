(adr-network-egress-jail)=

# 15. Jail Claude's egress in a per-process netns with a routing allowlist

Date: 2026-06-17

## Status

Accepted

Layers on top of {ref}`adr-network-egress-open` (ADR 5); does **not** reverse it.

## Context

ADR 5 left network egress open and said so deliberately: filtering "belongs at
the devcontainer boundary," and a future "add network sandboxing" would be *"a
layered addition on top of credential isolation — record it as its own ADR if
adopted; it does not reverse this decision."* This is that ADR.

The threat is **lateral movement, not exfil** (issue #31, folded into #56). bwrap
already hides credentials and the code is OSS; the asset worth protecting is
*network reach*. A compromised or prompt-injected session sharing the host
network namespace can probe RFC1918, hit internal HTTP and `169.254.169.254`,
and — the incident that motivates this — reach **lab devices with default creds**
(EPICS IOCs, PMAC). A PMAC reached by a hostile session is a *safety* incident,
not just an information one.

Two user cohorts need different controls:

- **Cohort A** — HTTPS to *named* hosts. Claude Code's native sandbox
  (`allowedDomains` / an SNI proxy) fits this; that is issue #33's scope.
- **Cohort B (this repo's users)** — lab devices addressed by **bare RFC1918 IP,
  over UDP, on dynamic ports** (EPICS CA/PVA, PMAC). A hostname allowlist
  *cannot express this*. Cohort B needs IP/CIDR-level control.

The runtime target is **rootless Podman** (pasta is the Podman 5+ default
outbound path). Consequences that rule out Docker-shaped designs: no host
`DOCKER-USER`/iptables knob for the unprivileged user, userspace outbound only,
and no `CAP_NET_ADMIN` on the container. So the control cannot be a host firewall
or a container capability — it has to be built from primitives an unprivileged
user already has.

Feasibility was probed **unjailed on a real rootless host** (the sandboxed
session reports `CapBnd=0`, a false "impossible" reading — see
{ref}`adr-untrusted-workspace`): unprivileged netns create + in-netns routing
with no caps **passes**, `pasta` builds a tap given `/dev/net/tun` **passes**, and
live egress through pasta — internet reachable, non-allowlisted RFC1918
blackholed — **passes**.

## Decision

Add an egress jail **beneath the bwrap wall**, scoped to Claude alone. The
container keeps `--network=host`, so ordinary (non-Claude) shells and EPICS
Channel Access broadcast are untouched. Only the shadow's launch is jailed:

- `claude-shadow` creates a **user + network namespace** with `unshare -rn`
  (a short-lived *holder*) and bwrap **inherits** it — bwrap keeps omitting
  `--unshare-net`; it only nests its own userns inside the holder's. (The holder
  must create the netns, not bwrap and not pasta: the container has no
  `CAP_NET_ADMIN` to make a netns without a userns, and if *pasta* creates the
  namespaces it also makes a pid+mount ns it can't give bwrap a usable `/proc`
  for — bwrap then aborts on `/proc/<pid>` lookups. A user+net-only holder keeps
  `/proc` valid so bwrap nests cleanly.)
- `pasta` **attaches from outside** the holder by PID (`pasta --config-net
  <holder-pid>`; it backgrounds itself). The egress proxy *must* run outside the
  netns — it needs host connectivity to proxy. No container caps, no host-firewall
  change. Note `--config-net` **mirrors the host's L3 config** into the netns: the
  host address, the **connected-subnet route**, the default gateway, and the DNS
  resolvers from `/etc/resolv.conf`.
- **Routing-as-allowlist (surgical)** inside the holder's netns. A *blanket*
  RFC1918 blackhole is wrong: on sites where the resolvers and gateway are
  themselves RFC1918 (e.g. an all-`172.23/16` lab network) it kills DNS, and
  pasta's mirrored connected-subnet route is *more specific* than the blackhole,
  so the whole local subnet stays reachable. Instead the holder: `blackhole`
  `10/8`, `172.16/12`, `192.168/16` **and the connected subnet**, `unreachable`
  `169.254/16`; then punches back only — the **gateway** (`/32`, on-link), the
  **DNS resolvers** (`/32` via gw; resolution is not lateral movement, since
  connections to internal IPs stay blackholed), and the **`allow-ip` devices**
  (`/32` via gw) from `/etc/claude-sandbox.conf`. The holder locks these down
  **before** handing off to bwrap — ordering (netns created → pasta attached →
  routes locked → *then* Claude runs) is load-bearing for the boundary. The
  blackholes are fail-closed (a failed one aborts the launch); the device/DNS
  punches are fail-soft (a missing one is lost reachability, not an open hole).
- **Security rests on userns ownership, not caplessness.** Claude is *not*
  capless here: because bwrap nests its userns inside the holder's unprivileged
  userns, the new userns grants Claude a **full** capability set (`CapBnd` =
  `…1ffffffffff`). That is expected and unavoidable. What contains it: the netns
  and its routes are owned by the **holder's** userns — an *ancestor* of Claude's
  — so Claude's caps confer no authority over them. Verified directly: from inside
  the jail, deleting a blackhole route, punching a route past it, and creating a
  net device all fail `EPERM`, and RFC1918 stays blocked after the attempts.

Two structural choices fix scope:

- **Bash, inlined in the shadow.** The setup is implemented as a `netns_setup()`
  function *inside* `claude-shadow`, not a sourced module — preserving the
  single-file, read-top-to-bottom auditability that {ref}`adr-bash-only` and
  {ref}`adr-integrity-surfaces` rest on. netns + routing + pasta *is* shell
  orchestration of CLI tools; the literal `ip route add blackhole …` commands are
  the most auditable representation of the boundary, so no higher-level language
  is warranted. (Trigger to revisit extraction into its own file — its own ADR —
  is if the net code outgrows the shadow's readability.)
- **Allowlist lives in `/etc`, not the workspace.** `allow-ip` entries come from
  `/etc/claude-sandbox.conf`, outside the sandbox's rw set, per
  {ref}`adr-untrusted-workspace`. A per-workspace allowlist would be
  attacker-writable from inside the jail.

## Consequences

- **Defence in depth, not a stronger wall.** This layer sits *beneath* bwrap: a
  bwrap *escape* could re-plumb the netns. It raises the cost of lateral movement
  for a contained session; it is never stronger than the bwrap boundary above it.
- **Channel Access broadcast for Claude is gone.** Claude's private netns has no
  LAN broadcast domain, so CA auto-discovery won't work *for Claude* — it must use
  unicast `EPICS_CA_ADDR_LIST`. Normal shells keep host networking and broadcast.
- **Requires `/dev/net/tun` in the container** (`devcontainer.json` runArgs
  `--device=/dev/net/tun`); pasta and slirp4netns are both TAP-based and neither
  works without it. This is the one hard container-side requirement.
- **`HTTPS_PROXY`-style env proxy is explicitly not the mechanism** (issue #31
  Option D): a hostile process unsets the env var or opens a raw socket. The
  control is enforced by ancestor-owned netns + kernel routing, not by environment.
- **`CapBnd=0` no longer holds inside the jail.** The nested userns gives Claude
  a full cap set, so any integrity check that asserts caplessness as proof of the
  sandbox (`sandbox-verify.sh`, `/verify-sandbox`) needs a **jail-aware variant**:
  when the jail is on, assert route-immutability (the `EPERM` battery above)
  instead of `CapBnd=0`. The non-jail path keeps asserting `CapBnd=0`. Full caps
  in Claude's *own* userns also warrant a check that no *other* bwrap protection
  (mount/ns operations within Claude's userns) is weakened — to confirm during
  implementation.
- **Hostname allowlists stay out of scope for Cohort B.** Native `allowedDomains`
  cannot express bare-IP/UDP/dynamic-port device traffic; Cohort A / dual-sandbox
  remains issue #33.
- **Gated, so dogfood ≈ guest is preserved.** The jail is opt-in via config; with
  it off, the launch path and guest installs are unchanged.
- **Verification follows the same three-surface model** as
  {ref}`adr-integrity-surfaces`: when the jail is enabled, `/verify-sandbox` gains
  a check that the netns exists and the RFC1918 blackhole holds with only the
  configured `allow-ip` routes punched through.
- **Proven before adoption:** the full Design-D chain — holder netns → pasta
  attach → route lockdown → nested capful bwrap → Claude — works on a real
  rootless host, *and* the route-immutability security battery passes
  (`probe-network-jail.sh`, run unjailed).
- **Still pending at adoption:** implementation in `claude-shadow` + `install.sh`
  + tests, the jail-aware `/verify-sandbox` check, and live verification of the
  Cohort B device path (`probe-network-jail.sh <device-ip>:<port>` against a real
  lab device — core internet/RFC1918 behaviour is already proven).

Live design and the feasibility probes: issue **#56** (refines #31, which is
closed; #33 remains open for Cohort A).
