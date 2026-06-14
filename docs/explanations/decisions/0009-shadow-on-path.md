(adr-shadow-on-path)=

# 9. Relocate the real Claude binary off PATH so the shadow always wins

Date: 2026-05-12

## Status

Accepted

## Context

Anthropic's `curl install.sh` drops the real Claude binary at
`~/.local/bin/claude` **and** prepends `$HOME/.local/bin` to the user's shell
rc. After the next shell, plain `claude` resolves there — *past* the bwrap
shadow at `/usr/local/bin/claude` — which is a sandbox escape.

## Decision

After install, **relocate** the real binary to
`/usr/libexec/claude-sandbox/claude` (off the user's PATH; commit `1f103a3`).
The shadow binds it back to `~/.local/bin/claude` *inside* the sandbox so
Claude's `installMethod=native` self-check still sees the conventional path.
Plain `claude` from any shell then always resolves to the shadow; you cannot
accidentally run the unwrapped binary from your normal shell.

## Consequences

- `tests/bwrap_argv.sh` scenarios 1 and 4a guard the relocate/bind-back pair.
- Acceptable swap: if Anthropic adds `--no-modify-path`, drop the relocate —
  *provided* plain `claude` still cannot resolve past `/usr/local/bin/claude`.
- Relocation closes the bypass for a fresh install, but Claude Code's
  auto-updater re-creates `~/.local/bin/claude` on a version bump, re-arming it.
  That second threat was closed later (2026-06-14) by hard-disabling the updater
  in the managed-settings layer — see {ref}`adr-managed-settings-guard`.
