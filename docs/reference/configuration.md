# Configuration

Reference for the two configuration surfaces: the host-global config
file `/etc/claude-sandbox.conf` and the `CLAUDE_SANDBOX_*` environment
variables. For task recipes see the [how-to guides](../how-to.md).

## `/etc/claude-sandbox.conf`

The shadow reads this file at every launch. It is installed by
`install.sh` from the clone's `.devcontainer/claude-sandbox.conf` and
re-stamped on every rebuild via postCreate. It lives at `/etc`, **not**
in the rw-bound workspace, so a compromised session cannot rewrite it
to widen the next launch's binds. To change it, edit the clone conf and
re-run `./install` (a rebuild does it via postCreate).

A missing file is a no-op (`parse_config` returns). The installer
skips placing it if the clone carries no conf. File mode is `0644`.

### Format

- One directive per line.
- `key = value`, or a bare `key` for boolean flags.
- Blank lines and `#` comments are ignored.
- Environment variables already set take precedence — the config
  supplies defaults.

### Keys

| Key | Value | Effect |
|---|---|---|
| `workspace-root` | absolute path | Sets the rw bind-mount root if `CLAUDE_SANDBOX_WORKSPACE_ROOT` is not already set. Empty value ignored |
| `no-forge` | bare flag (no value) | Equivalent to `CLAUDE_SANDBOX_NO_FORGE=1`: skips the `gh`/`glab` token binds and removes the credential helpers from the generated gitconfig |
| `allow-write` | absolute path | Adds an extra writable bind. Repeatable — each `allow-write` line appends one path. Empty values skipped; non-existent paths are skipped at bind time |

```ini
# .devcontainer/claude-sandbox.conf  (installed to /etc/claude-sandbox.conf)
allow-write = /cache
allow-write = /workspaces/sibling-project
```

## Environment variables

Set these in your devcontainer's `remoteEnv` (restart or rebuild for the
change to take effect). Names below are verified against the shadow and
installer sources.

| Variable | Set by / read by | Meaning |
|---|---|---|
| `CLAUDE_SANDBOX_WORKSPACE_ROOT` | you (`remoteEnv`) → shadow | Explicit rw bind-mount root. Set to `/workspaces` to restore the old broad bind; any absolute path for a custom root. Default when unset: `$PWD` |
| `CLAUDE_SANDBOX_NO_FORGE` | you (`remoteEnv`) → shadow | `1` skips the `gh`/`glab` token binds and drops the credential helpers from the generated gitconfig, so `git push` fails inside the sandbox by design |
| `CLAUDE_SANDBOX_ALLOW_UNWRAPPED` | you → guard scripts | `1` downgrades the `UserPromptSubmit` gate to warn-only when Claude is running unwrapped (the `SessionStart` warning still shows) |
| `IS_SANDBOX` | set by bwrap (`--setenv IS_SANDBOX 1`) | Sentinel proving the sandbox was entered. The shadow's recursion guard falls through to the real binary when it is `1`; the gate blocks every prompt unless it is `1` |
| `CLAUDE_SANDBOX_ALLOW_WRITE` | populated by `parse_config` from `allow-write` lines | Newline-separated extra writable paths bound in addition to the workspace |
| `CLAUDE_SANDBOX_GITCONFIG_PATH` | exported by the shadow | Path to the curated gitconfig (`/etc/claude-gitconfig`) consumed by the argv builder |
| `CLAUDE_CODE_REMOTE` | Claude Code Web | When `true`, both guard scripts skip (the guard does not run on Claude Code Web) |
| `DISABLE_AUTOUPDATER` | set to `1` in managed settings by `install.sh` | Disables Claude Code's in-container auto-updater (alongside `autoUpdates:false`) so a self-update can't re-arm the unwrapped-launch bypass |

`CLAUDE_SANDBOX_NO_FORGE` is documented as a task in
[run a no-push session](../how-to/run-without-push-access.md); workspace scope
is covered in [widen the writable workspace](../how-to/configure-workspace-scope.md).
