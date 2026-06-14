# What's installed

The files `./install` places, by scope. For the configuration these
files read, see [configuration](configuration.md).

## Container-scoped

Re-established by re-running `./install`, typically wired into
`postCreate.sh`.

| Path | Source | Purpose |
|---|---|---|
| `/usr/libexec/claude-sandbox/claude` | Anthropic installer (`curl -fsSL https://claude.ai/install.sh \| bash`), relocated | The real Claude binary, kept off the user's PATH so the shadow always wins |
| `/usr/local/bin/claude` | `.devcontainer/claude-sandbox/claude-shadow` (verbatim) | Shadow that wraps the real binary in `bwrap`. Falls through to the real binary when `IS_SANDBOX=1` so internal `claude` invocations from a hook don't recurse |
| `/etc/claude-gitconfig` | Generated | Curated gitconfig — regenerated from `git config --get user.{name,email}` on every shadow launch |
| `/usr/libexec/claude-sandbox/sandbox-verify.sh` | `.devcontainer/claude-sandbox/sandbox-verify.sh` | `SessionStart` guard script — full integrity battery + loud warn when unwrapped. Off-PATH, root-owned, ro inside the sandbox |
| `/usr/libexec/claude-sandbox/sandbox-gate.sh` | `.devcontainer/claude-sandbox/sandbox-gate.sh` | `UserPromptSubmit` guard script — sub-second fail-closed gate (`IS_SANDBOX=1` or block). Same protections |
| `/etc/claude-code/managed-settings.json` | jq-merged by `install.sh` | The GLOBAL guard policy. Adds the two hooks (deduped by basename), sets `env.DISABLE_AUTOUPDATER=1` + `autoUpdates:false`. Highest-precedence + user-uneditable, so removing the hooks from `~/.claude/settings.json` does **not** disable the guard. Any real admin policy already in the file is preserved; `allowManagedHooksOnly` is deliberately **not** set (your own hooks still run) |
| `/etc/claude-sandbox.conf` | `.devcontainer/claude-sandbox.conf` (skip-if-absent) | Host-global sandbox config read by the shadow at launch — see [configuration](configuration.md) |

Disabling the auto-updater is root-cause removal: Claude Code's updater
otherwise re-creates `~/.local/bin/claude` on a version bump, which can
launch the real binary unwrapped and self-entrench. With the updater
off, updates happen only via a deliberate `./install`, which
re-relocates the current binary and re-asserts the shadow. See the
[shadow-on-PATH explanation](../explanations/integrity-guard.md).

## User-scope `~/.claude`

Preference only — the guard does **not** live here.

| Path | Behaviour |
|---|---|
| `~/.claude/statusline-command.sh` | Statusline — seeded **only if absent** (an owner-customised one survives) |
| `~/.claude/settings.json` | `.statusLine` set only if absent; otherwise untouched. If an earlier install put the guard here, those hook entries are pruned so the guard has a single authoritative home (`/etc`). All other keys — yours — preserved |

Not placed: `CLAUDE.md` and `README-CLAUDE.md` live in the meta-repo for
dogfooding.
