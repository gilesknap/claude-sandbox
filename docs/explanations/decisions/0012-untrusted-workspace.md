(adr-untrusted-workspace)=

# 12. Treat the read-write workspace as untrusted: default to $PWD, source config from /etc

Date: 2026-05-29

## Status

Accepted

## Context

The workspace is bound rw into the sandbox, so a compromised session can write
to it. Two facets followed from taking that seriously. (1) The early bind
exposed all of `/workspaces` — every sibling project — rw. (2) Sandbox config
(`workspace-root`, `allow-write`, …) was first read from
`$PWD/.devcontainer/claude-sandbox.conf`, *inside* the rw workspace.

## Decision

Treat the rw workspace as **attacker-writable input**, on two fronts:

- **Default the workspace bind to `$PWD`** — only the current project is
  writable (PR #29, issue #28). Restoring the broad `/workspaces` bind is an
  explicit opt-in (`CLAUDE_SANDBOX_WORKSPACE_ROOT=/workspaces`).
- **Read sandbox config from host-global `/etc/claude-sandbox.conf`**, never
  from the workspace (PR #32, commit `f6fcc3d`). `/etc` is not in the rw bind
  set. A per-workspace conf is attacker-writable from inside the jail: a
  compromised session could write `allow-write = /` (or `workspace-root = /`)
  and the *next* launch would `--bind` it rw — a cross-session breakout.

## Consequences

- One global conf applies to every workspace with nothing added per repo; edit
  the clone conf and re-run `./install` (a rebuild does it via `postCreate`) to
  change it. Per-session `CLAUDE_SANDBOX_*` env vars remain the supported
  per-session override.
- `verify-sandbox` check 18 guards that the installed shadow reads `/etc` and
  has no `$PWD/.devcontainer` read.
- Refuse "make `allow-write` per-repo again so projects can opt in" — it reopens
  the bind-escalation vector. The same "security-relevant inputs live outside
  the rw set" discipline governs where the integrity guard lives
  ({ref}`adr-managed-settings-guard`). A residual re-stamp vector (the global
  conf is itself re-placed from the clone on rebuild) is tracked in issue #35.
