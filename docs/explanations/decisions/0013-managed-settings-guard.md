(adr-managed-settings-guard)=

# 13. Deliver the integrity guard globally via managed-settings

Date: 2026-06-14

## Status

Accepted

## Context

A guard must assert "Claude is actually inside the shadow" in **every** folder —
even ones with no project `.claude/`. Two earlier designs failed: per-repo
project `.claude/` hooks left un-promoted folders unguarded; an intermediate
user-scope `~/.claude/settings.json` design was silently removable by editing
that shared, cross-container file.

## Decision

Deliver the guard through Claude Code's **managed-settings** layer
(`/etc/claude-code/managed-settings.json`) — the highest-precedence tier, which
a user cannot override or remove from user-scope — with two hooks whose scripts
live in `/usr/libexec/claude-sandbox/` (root-owned, off-PATH, **ro inside the
sandbox**):

- `SessionStart → sandbox-verify.sh`: advisory full integrity battery, warns
  loudly when unwrapped (SessionStart cannot block).
- `UserPromptSubmit → sandbox-gate.sh`: fail-closed, `exit 2` unless
  `IS_SANDBOX=1`. Escape hatch is the root-owned flag
  `/etc/claude-code/allow-unwrapped` (a flag under `/etc`, not an env var,
  so a confined Claude can't forge it via `~/.claude/settings.json`'s
  exported `env` block — deep-review H4); both skip on
  `CLAUDE_CODE_REMOTE=true`.

This is the same "security inputs live outside the rw workspace" discipline as
{ref}`adr-untrusted-workspace`: under `~/.claude` the scripts would be rw-bound
and a compromised session could rewrite the gate to `exit 0`.

## Consequences

- Editing `~/.claude/settings.json` cannot disable the guard — only `root`
  editing `/etc` or a deliberate `./install` can.
- We deliberately do **not** set `allowManagedHooksOnly` (managed hooks are
  additive — the owner's own hooks still run). `wire_user_statusline` prunes any
  guard hooks an earlier user-scope install left behind, so the guard has one
  authoritative home.
- The same managed layer also **hard-disables the in-container auto-updater**
  (`DISABLE_AUTOUPDATER=1` + `autoUpdates:false`; first shipped in this work,
  commit `f4928d4`). This is root-cause removal of a PATH-bypass re-arm: the
  updater otherwise re-creates `~/.local/bin/claude` unwrapped on a version bump
  (see {ref}`adr-shadow-on-path`), so updates become a deliberate `./install`
  that re-relocates the binary and re-asserts the shadow.
  `autoUpdatesChannel:"stable"` only *slows* updates and would not fix this.
- Refuse: moving the guard back to per-repo/user-scope; putting the scripts in
  the sandbox rw set; setting `allowManagedHooksOnly`; or hard-failing install
  over a non-JSON settings file we don't exclusively own (warn-and-skip
  instead). Fleet-wide enforcement against *accidental* unwrapped host `claude`
  (issue #41) extends this layer.
