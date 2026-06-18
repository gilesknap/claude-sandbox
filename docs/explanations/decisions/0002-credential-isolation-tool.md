(adr-scope-credential-isolation)=

# 2. A credential-isolation tool, not a general-purpose sandbox

Date: 2026-05-10

## Status

Accepted

## Context

We had to fix the scope of the guarantee before designing any defence. The
adversary is an LLM-driven attack — a hostile prompt, a hostile file Claude
reads, or a hostile tool result — running Claude Code inside a developer's
devcontainer and trying to exfiltrate host credentials, drive the host IDE, or
escalate privileges. The tempting-but-wrong framing is "a sandbox that contains
arbitrary code"; that promises far more than bwrap-in-a-rootless-container can
honestly deliver, and it invites bug reports for threats we never claimed to
stop.

## Decision

Scope the tool to **credential isolation against an in-container LLM
adversary**, not a general-purpose sandbox against arbitrary native code.
Enforcement targets *accidental* and *LLM-driven* exposure, not a determined
human who already controls the host. Explicitly out of scope: a bwrap-aware
kernel exploit; the workspace contents themselves (Claude must read them to do
its job — keep secrets out of the workspace); non-standard credential mounts the
user adds; non-root devcontainers (tracked for v2). Internet-domain / exfil
filtering is out of scope and gets its own record — see
{ref}`adr-network-egress-open`. Lateral network isolation (blackholing RFC1918
so a compromised session cannot pivot to internal hosts) was later brought
*into* scope as a layer around the tool — see {ref}`adr-network-egress-jail`.

## Consequences

- Every defence maps to one observed exfiltration path (env vars, dotfiles, IPC
  sockets, X11, TIOCSTI, sudo) and the bwrap primitive that closes it, rather
  than to a generic "escape" notion. `README-CLAUDE.md`'s threat-model table is
  the authoritative scope.
- "It doesn't stop a kernel exploit" and "Claude can read my workspace" are
  documented non-goals, not bugs. The mitigation for workspace secrecy is
  yours: keep secrets outside the workspace.
- A future "make it a real sandbox against native code" proposal is a different
  product with a different threat model, not an increment on this one.
