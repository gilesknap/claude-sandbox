[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)

# claude-sandbox

bwrap-isolated Claude Code for Debian/Ubuntu devcontainers (rootless
Podman is the supported runtime; rootless Docker works too). A
hostile prompt, file, or tool result cannot reach your host
credentials, IDE bridges, or shell environment.

📖 **Full documentation:** <https://gilesknap.github.io/claude-sandbox/>
— Diátaxis-organised tutorials, how-to guides, reference, and an
[architecture overview](https://gilesknap.github.io/claude-sandbox/explanations/architecture.html)
with diagrams. Built from `docs/` with Sphinx and published to GitHub
Pages on every push to `main`.

## Quickstart

Inside any Debian/Ubuntu devcontainer (running as `root`, typical
rootless-podman pattern):

```
git clone https://github.com/gilesknap/claude-sandbox.git
cd claude-sandbox
./install
```

Then run `claude` as usual — the shadow on `$PATH` wraps every
invocation in `bwrap`. Run `/verify-sandbox` from inside a session
to confirm the 18-check battery + 10 adversarial breakout probes
pass.

The installer is idempotent: re-run after a devcontainer rebuild and
the shadow is re-established without re-downloading Claude. Wire
`bash <clone>/install` into your devcontainer's `postCreate.sh` to
automate that step.

### Devcontainers using terminal-config (e.g. python-copier-template)

If your devcontainer bind-mounts `~/.config/terminal-config` at
`/user-terminal-config` (the `python-copier-template` convention),
clone there instead:

```
cd /user-terminal-config
git clone https://github.com/gilesknap/claude-sandbox.git
cd claude-sandbox
./install
```

The clone lives on the host under `~/.config/terminal-config`, so it
survives devcontainer rebuilds and is reusable from every
devcontainer that mounts the same terminal-config dir — one clone,
every project sandboxed.

## What you get

- A shadow `/usr/local/bin/claude` that auto-wraps the real Claude
  binary (relocated to `/usr/libexec/claude-sandbox/claude` so it
  sits off the user's PATH — Anthropic's installer drops it at
  `~/.local/bin/claude` and prepends `~/.local/bin` to your shell rc,
  which would otherwise let plain `claude` bypass the shadow) in a
  `bwrap` sandbox with `--ro-bind / /` + `--tmpfs $HOME`,
  `--clearenv`, `--cap-drop ALL`, `--unshare-pid/ipc/uts`, TIOCSTI
  defence via `script(1)`, and the rest of the threat model.
- A curated `/etc/claude-gitconfig` so `git push` works inside the
  sandbox via `gh` / `glab` as the credential helper. Regenerated on
  every launch from your host's current `user.name` / `user.email`.
- A **global integrity guard** delivered through Claude Code's
  highest-precedence **managed-settings** layer
  (`/etc/claude-code/managed-settings.json`), so it fires in *every*
  folder and **can't be removed by editing your own
  `~/.claude/settings.json`**: a `SessionStart` hook
  (`sandbox-verify.sh`) that runs the full integrity battery and warns
  loudly when Claude is unwrapped, plus a sub-second `UserPromptSubmit`
  gate (`sandbox-gate.sh`) that **blocks every prompt** unless
  `IS_SANDBOX=1` — defence against the "Claude launched via a non-shadow
  path" bypass. The guard scripts live in `/usr/libexec/claude-sandbox`
  (off-PATH, read-only inside the sandbox). The installer also disables
  Claude Code's auto-updater (`DISABLE_AUTOUPDATER=1`) so the bypass
  can't silently re-arm. See [Keeping the shadow on
  PATH](#keeping-the-shadow-on-path) below.
- **Refusal-on-failure**: if the host can't run unprivileged user
  namespaces, the installer refuses with a specific actionable
  diagnostic — never installs a non-functional sandbox.

## Threat model

See [`README-CLAUDE.md`](./README-CLAUDE.md). TL;DR: in scope are
host credentials reachable via `$HOME` dotfiles, env vars,
`/run/secrets`, VS Code IPC sockets in `/tmp`, X11 reachability, and
TIOCSTI terminal injection. Out of scope are workspace contents
(Claude has to read your workspace) and arbitrary kernel exploits.

## Verifying

```
/verify-sandbox        # inside Claude
```

Runs the 18 PASS/FAIL battery + 10 adversarial breakout probes
against the live process and exits non-zero on any FAIL. The spec
lives at `.claude/commands/verify-sandbox.md`.

## Upgrading

```
git pull --ff-only && bash install
```

The installer is idempotent; the shadow is re-established without
re-downloading Claude.

## Keeping the shadow on PATH

The protection is launch-time: plain `claude` must resolve to the
shadow at `/usr/local/bin/claude`, which `bwrap`-wraps the real binary
relocated to `/usr/libexec/claude-sandbox/claude`. **Claude Code's
auto-updater re-creates `~/.local/bin/claude` on every version bump**,
which (depending on your `PATH` order) can launch the real binary
*unwrapped* — no bwrap, no git steering — and is self-entrenching and
silent. This happened in practice: a self-update quietly disabled the
sandbox for days.

Two mechanisms close this:

1. **The installer disables the in-container auto-updater**
   (`env.DISABLE_AUTOUPDATER=1` + `autoUpdates:false`), so updates only
   happen when *you* re-run `./install` — which re-relocates the current
   binary and re-asserts the shadow.
2. **The global guard fails loud (and closed) if it ever happens
   anyway.** A `SessionStart` hook warns at launch and the
   `UserPromptSubmit` gate blocks every prompt while unwrapped, telling
   you to re-run `claude-sandbox/install`. To work unwrapped on purpose,
   export `CLAUDE_SANDBOX_ALLOW_UNWRAPPED=1` (the SessionStart warning
   still shows; the gate stops blocking).

### Where the guard lives (and why it's tamper-resistant)

The guard is delivered through Claude Code's **managed-settings** layer,
which mirrors the same `/etc`-not-the-workspace discipline as the
sandbox config (see [Workspace scope](#workspace-scope)):

- **Hook entries** go in `/etc/claude-code/managed-settings.json` — the
  *highest-precedence* settings layer. It runs in every folder, and a
  user editing their own `~/.claude/settings.json` **cannot remove or
  override it**. Only `root` editing `/etc` (or a deliberate `./install`)
  changes it.
- **Hook scripts** go in `/usr/libexec/claude-sandbox/` — root-owned,
  off-PATH, and **read-only inside the sandbox** (`--ro-bind / /`), so a
  compromised in-session Claude can't rewrite them to `exit 0`.

The installer merges the guard in idempotently (preserving any real
enterprise admin policy already in that file) and deliberately does *not*
set `allowManagedHooksOnly`, so your own user/project hooks still run.
Your `~/.claude/settings.json` keeps only your `statusLine` preference
(set only if absent); the guard no longer lives anywhere you might edit
it away by accident.

This makes the **native claude-sandbox devcontainer** (and any promoted
target) safe-by-construction: short of `root` deleting the `/etc` policy
file, you cannot accidentally disable the guard.

## Promoting into a host workspace

`just promote` makes a target workspace a self-sufficient claude-sandbox
host — a teammate who clones the target only needs the devcontainer to
come up; the installer runs from `postCreate.sh` and the curated
`.claude/` is in tree.

```
just promote                       # promote into $PWD
just promote /workspaces/fastcs    # promote into the named target
```

Three things land in the target:

1. **Curated `.claude/`** — commands and skills. The integrity guard is
   **not** seeded per-repo; it's global (wired into `~/.claude` by
   `install.sh`, which the target's `postCreate` runs), so promote no
   longer touches the target's project `settings.json`, hooks, or
   statusline.
2. **Install machinery** — `.devcontainer/claude-sandbox/{install.sh,
   claude-shadow, promote.sh}`, so postCreate can run install.sh
   directly. The root `install` shim is *not* copied; it's the source
   repo's manual-UX entry and not a primary workflow for targets. The
   cost is ~3 small bash files per promoted repo; re-running
   `just promote` from this clone re-syncs byte-equal.
3. **`.devcontainer/postCreate.sh`** running
   `bash .devcontainer/claude-sandbox/install.sh` — created if absent,
   idempotently appended otherwise.

After it finishes, promote prints a one-line `"postCreateCommand"`
snippet to paste into the target's `.devcontainer/devcontainer.json`.
We deliberately don't auto-edit that file: it's JSONC in the wild,
structured editing while preserving comments is more code than this
repo wants, and you're the one who knows whether you've already wired
it or need to combine with an existing `postCreateCommand`. One-time
edit; subsequent `just promote` runs are byte-stable.

`just promote` is idempotent, refuses self-targeting (`TARGET == clone`),
and does NOT touch `~/.claude`. The global integrity guard lives in
`/etc/claude-code/managed-settings.json` + `/usr/libexec/claude-sandbox/`,
written by `install.sh` (which the target's `postCreate` runs), not by
promote — so the shared `~/.claude` channel stays reserved for
cross-container state (OAuth, memories) and promote's per-repo writes
stay minimal.

## Workspace scope

The sandbox makes only `$PWD` writable by default — sibling projects
under `/workspaces/` are read-only. To restore the old broad bind:

```jsonc
// .devcontainer/devcontainer.json → remoteEnv
"CLAUDE_SANDBOX_WORKSPACE_ROOT": "/workspaces"
```

For extra writable paths without widening to all of `/workspaces`, add
`allow-write` lines to the sandbox config. Edit it in the clone at
`.devcontainer/claude-sandbox.conf`; `install.sh` copies it to the
host-global `/etc/claude-sandbox.conf` the shadow reads at launch (a
devcontainer rebuild re-stamps it via postCreate, or re-run `./install`).
Blank lines and `#` comments are ignored; non-existent paths are skipped:

```ini
# .devcontainer/claude-sandbox.conf  (installed to /etc/claude-sandbox.conf)
allow-write = /cache
allow-write = /workspaces/sibling-project
```

## Authenticating with forges

```
just gh-auth
just glab-auth                  # gitlab.com
just glab-auth gitlab.diamond.ac.uk
```

Both walk you through a fine-grained-PAT prompt, feed the token to
the respective CLI's `auth login`, and unset the variable. Tokens
never enter shell history.

### PAT hygiene

`gh`/`glab` tokens are bound rw into the sandbox so Claude can push.
Minimise blast radius: use fine-grained single-repo PATs with a 7–30
day expiry and no `workflow` or admin scopes. See
[`README-CLAUDE.md`](./README-CLAUDE.md#pat-hygiene) for the full
guidance.

To run a session where Claude can't push at all, set
`CLAUDE_SANDBOX_NO_FORGE=1` in your devcontainer's `remoteEnv` (a
commented example is in `.devcontainer/devcontainer.json`). This
skips the `gh`/`glab` token binds and removes the credential helpers
from the generated gitconfig.

## Development

```
git clone https://github.com/gilesknap/claude-sandbox.git
cd claude-sandbox
bash tests/bwrap_argv.sh
bash tests/smoke.sh
bash tests/promote.sh
```

Same three commands CI runs. No `uv sync`, no pytest, no twine —
bash all the way down.

The repo's own `.claude/` IS the canonical source of shipped skills,
commands, and hooks — editing one updates both how Claude behaves on
this repo AND what the installer ships into target workspaces.

## License

See [`LICENSE`](./LICENSE).
