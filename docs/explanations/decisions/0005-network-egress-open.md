(adr-network-egress-open)=

# 5. Leave network egress open; egress filtering is out of scope

Date: 2026-05-11

## Status

Accepted

Superseded **in part** by {ref}`adr-network-egress-jail` (ADR 15): as of
2026-06-18 the per-process egress jail is the **default**, so egress is no longer
open by default for Claude. This ADR's analysis still holds — the jail sits
*around* the tool (a holder netns beneath bwrap), not as an in-core firewall, and
`CLAUDE_SANDBOX_EGRESS_JAIL=0` restores the open-egress path this ADR describes.

## Context

Claude Code must reach `api.anthropic.com`, and GitHub/GitLab for pushes. A
session that shares the host network namespace can also enumerate the host's
interfaces, routing table, and DNS resolver, and reach internal services on the
same host network. Layering egress filtering or full network sandboxing on top
is a recurring proposal (issues #31, #33).

## Decision

Share the host network namespace — the bwrap argv deliberately omits
`--unshare-net` — and do **not** run a per-process egress firewall. Network
egress is deliberately open. This is
an explicit *no*: egress filtering is out of scope for this tool (see
{ref}`adr-scope-credential-isolation`). It belongs at the devcontainer boundary —
run the container itself behind an egress filter if you need one.

## Consequences

- There is no PASS/FAIL check for egress: a regression makes Claude fail on
  first use, loudly, rather than silently degrading.
- Network-identity disclosure (host IPs, routes, `/etc/resolv.conf` visible from
  inside) is **accepted**. It is information disclosure, not credential exfil;
  `/verify-sandbox` flags it as an `[INCONCLUSIVE]` adversarial probe so it
  stays on the radar. Don't run a loopback/RFC1918 credential service on a host
  that also runs `claude`.
- A future "add network sandboxing" (issues #31/#33) is a *layered* addition on
  top of credential isolation — record it as its own ADR if adopted; it does not
  reverse this decision.
