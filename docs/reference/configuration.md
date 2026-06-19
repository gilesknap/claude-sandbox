# Configuration

Reference for the two configuration surfaces: the host-global config
file `/etc/claude-sandbox.conf` and the `CLAUDE_SANDBOX_*` environment
variables. For task recipes see the [how-to guides](../how-to.md).

## `/etc/claude-sandbox.conf`

The shadow reads this file at every launch. It is installed by
`install.sh` from the clone's `.devcontainer/claude-sandbox.conf` and
re-stamped on every rebuild via postCreate. It lives at `/etc`, **not**
in the rw-bound workspace, so a compromised session cannot rewrite it
to widen the next launch's binds — or, with `allow-ip`, its network
reach. To change it, edit the clone conf and
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
| `egress-jail` | `0` to disable; bare flag / `1` reaffirms on | The per-process network egress jail ({ref}`adr-network-egress-jail`) is **ON by default**; this key only needs to appear to **turn it off** on a host: `egress-jail = 0` (restores {ref}`adr-network-egress-open`'s shared-host-netns, no-firewall behaviour). A bare `egress-jail` reaffirms on. `CLAUDE_SANDBOX_EGRESS_JAIL` in the environment takes precedence over this key |
| `allow-ip` | bare IP (no CIDR) | A device IP the egress jail keeps reachable past its RFC1918 blackhole (e.g. an EPICS IOC / PMAC / internal GitLab by bare address). Repeatable — each line punches one `/32` route via the gateway. Lives in `/etc`, not the workspace, so a compromised session cannot widen its own network reach. No effect when the jail is disabled |

```ini
# .devcontainer/claude-sandbox.conf  (installed to /etc/claude-sandbox.conf)
allow-write = /cache
allow-write = /workspaces/sibling-project

# Egress jail is ON by default; uncomment to disable on this host.
# egress-jail = 0
# Keep these device IPs reachable past the RFC1918 blackhole (bare IP):
allow-ip = 172.23.142.119  # internal GitLab
```

## Environment variables

Set these in your devcontainer's `remoteEnv` (restart or rebuild for the
change to take effect). Names below are verified against the shadow and
installer sources.

| Variable | Set by / read by | Meaning |
|---|---|---|
| `CLAUDE_SANDBOX_WORKSPACE_ROOT` | you (`remoteEnv`) → shadow | Explicit rw bind-mount root. Set to `/workspaces` to restore the old broad bind; any absolute path for a custom root. Default when unset: `$PWD` |
| `CLAUDE_SANDBOX_NO_FORGE` | you (`remoteEnv`) → shadow | `1` skips the `gh`/`glab` token binds and drops the credential helpers from the generated gitconfig, so `git push` fails inside the sandbox by design |
| `ALLOW_UNWRAPPED` | you → `install.sh` (install-time) | `1` stamps the root-owned gate escape-hatch flag `/etc/claude-code/allow-unwrapped`; unset/`0` leaves the gate fail-closed and removes a stale flag. Replaces the retired `CLAUDE_SANDBOX_ALLOW_UNWRAPPED` env hatch, which a confined Claude could forge via `~/.claude/settings.json` (deep-review H4) |
| `CLAUDE_SANDBOX_EGRESS_JAIL` | you (env, per session) / conf `egress-jail` → shadow | Network egress jail toggle ({ref}`adr-network-egress-jail`). Default **ON**; set to `0` to launch without the jail (restores the shared host netns, no per-process firewall, per {ref}`adr-network-egress-open`). Env value wins over the `egress-jail` conf key. The jail is fail-closed: with it on but `/dev/net/tun` / pasta / `unshare` missing, `claude` refuses to launch and the error names this escape hatch |
| `CLAUDE_SANDBOX_ALLOW_IP` | populated by `parse_config` from `allow-ip` lines | Newline-separated device IPs the jail keeps reachable past the RFC1918 blackhole |
| `IS_SANDBOX` | set by bwrap (`--setenv IS_SANDBOX 1`) | Sentinel proving the sandbox was entered. The shadow's recursion guard falls through to the real binary when it is `1`; the gate blocks every prompt unless it is `1` |
| `CLAUDE_SANDBOX_ALLOW_WRITE` | populated by `parse_config` from `allow-write` lines | Newline-separated extra writable paths bound in addition to the workspace |
| `CLAUDE_SANDBOX_GITCONFIG_PATH` | exported by the shadow | Path to the curated gitconfig (`/etc/claude-gitconfig`) consumed by the argv builder |
| `CLAUDE_CODE_REMOTE` | Claude Code Web | When `true`, both guard scripts skip (the guard does not run on Claude Code Web) |
| `DISABLE_AUTOUPDATER` | set to `1` in managed settings by `install.sh` | Disables Claude Code's in-container auto-updater (alongside `autoUpdates:false`) so a self-update can't re-arm the unwrapped-launch bypass |

`CLAUDE_SANDBOX_NO_FORGE` is documented as a task in
[run a no-push session](../how-to/run-without-push-access.md); workspace scope
is covered in [widen the writable workspace](../how-to/configure-workspace-scope.md).

## Gate escape-hatch flag: `/etc/claude-code/allow-unwrapped`

The `UserPromptSubmit` gate ([integrity guard](../explanations/integrity-guard.md))
is fail-closed: it blocks every prompt unless Claude is inside the bwrap
shadow (`IS_SANDBOX=1`). To allow working **unwrapped**, the operator
creates a root-owned flag file:

```console
$ sudo touch /etc/claude-code/allow-unwrapped   # downgrade gate to warn-only
$ sudo rm   /etc/claude-code/allow-unwrapped    # restore fail-closed
```

or runs `ALLOW_UNWRAPPED=1 ./install` (a later `./install` without that
variable removes the flag again). The `SessionStart` warning still fires —
unwrapped is allowed, never silent.

It is deliberately a flag under `/etc`, **not** an environment variable:
`/etc` is root-owned, read-only inside the sandbox (`--ro-bind / /`), and
not part of the host-shared `~/.claude`. A confined Claude can write
`~/.claude/settings.json` (host-shared, persistent) and Claude Code
exports that file's `env` block into later sessions, so an env-var hatch
was forgeable from inside the jail and would persistently neutralise the
gate on a later unwrapped launch (deep-review **H4**). Only `root` on the
host can create this flag.
