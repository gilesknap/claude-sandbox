# Deliberately exposed and out of scope

Anything not in the lockdown list (see the [threat model](../explanations/threat-model.md))
is reachable from inside Claude. This page reproduces the two reference
tables: what the sandbox deliberately exposes, and what is out of scope.

## Deliberately exposed

These paths are bound into the sandbox on purpose. Modes are `r`
(read-only) or `rw` (read-write).

| Path | Mode | Why |
|---|---|---|
| Workspace | rw | The whole point of Claude. Default: `$PWD` (only the current project is writable). Override: set `CLAUDE_SANDBOX_WORKSPACE_ROOT=/workspaces` in `remoteEnv` to restore the old broad bind and make sibling devcontainer projects writable. Extra paths: `allow-write = <abs-path>` lines in `/etc/claude-sandbox.conf` (one path per line; blank lines and `#` comments ignored) |
| `/etc/claude-sandbox.conf` | r | Host-global sandbox config (`workspace-root`, `no-forge`, `allow-write`), placed by `install.sh` from the clone's `.devcontainer/claude-sandbox.conf` and read by the shadow at launch. Lives at `/etc`, **not** in the rw-bound workspace, so a compromised session can't rewrite it to widen the next launch's binds. Edit the clone conf + re-run `./install` (a rebuild does it via postCreate) to change it |
| `/etc/claude-gitconfig` | r | Curated gitconfig: gh/glab credential helpers for `https://github.com` and `https://gitlab.diamond.ac.uk`, ssh→https `insteadOf` rewrites, regenerated at every shadow launch from your host's current `user.name`/`user.email` |
| `/etc/gitconfig` | r | Host's system gitconfig is reachable read-only but neutralised for `git` because `GIT_CONFIG_SYSTEM=/dev/null` |
| `/root/.claude/` | rw | Claude's state, settings, skills, hooks. `install.sh` symlinks this to `/user-terminal-config/.claude` so the tree persists across rebuilds and is shared with every other devcontainer that mounts the same `terminal-config` dir |
| `/root/.claude.json` | rw | Account-level state (OAuth token, recent-projects list, settings). Symlinked alongside `~/.claude/`; without it the strict-under-/root tmpfs would swallow the token and re-prompt login every launch |
| `/root/.cache/` | rw | Tool caches Claude needs across runs (if present) |
| `/root/.config/gh/` | rw | `gh` CLI's token store. Required so `gh auth status` works and the curated gitconfig's `gh auth git-credential` helper can authenticate `git push` to GitHub without an OAuth popup |
| `/root/.config/glab-cli/` | rw | `glab` CLI's token store. Same reason as `gh`. Sibling paths under `/root/.config/` (VS Code state, other cred helpers, etc.) are NOT bound |
| `/root/.local/share/` + single files `/root/.local/bin/{uv,uvx}` | rw | Bulk-bound XDG data dir: host-installed plugins for `helm`, `kubectl`/`krew`, `uv`-managed Python, etc. just work inside the sandbox without per-tool allowlist additions. `applications/` and `claude/` are tmpfs-masked so Claude Code's own writes (URL handler `.desktop`, versioned binary cache) stay ephemeral. `.config/` stays strict-allowlist — credentials live there, not under `.local/share/` |
| `/usr/libexec/claude-sandbox/claude` | r | The real Claude binary, relocated here by the installer from `~/.local/bin/claude` so plain `claude` on the user's PATH always resolves to the shadow. The shadow exec's this same file via `bwrap`; a bind back to `~/.local/bin/claude` inside the sandbox keeps Claude Code's `installMethod=native` self-check happy |
| Network (`--share-net`) | — | Claude needs `api.anthropic.com` + GitHub/GitLab |

For the rationale behind the XDG split, the uv bind discipline, the
gitconfig redirect, and the network-identity disclosure, see the
[threat model](../explanations/threat-model.md).

## Out of scope

The sandbox does not defend against the following. Each row names the
mitigation expected from you.

| Exposure | Why | Mitigation expected from you |
|---|---|---|
| **Workspace contents** | Claude has to read your workspace to do its job | Keep secrets outside the workspace (e.g. `~/.config/` mounted via your devcontainer's `mounts`). Don't put `.env` files with production credentials at the workspace root and expect them to be invisible |
| **Container host kernel** | A bwrap-aware kernel exploit is out of scope; this is a credential-isolation tool, not a sandbox against arbitrary native code | Keep your kernel patched; treat the devcontainer host as the trust boundary |
| **Network egress filtering** | Claude needs network. The sandbox shares the netns and does not run a per-process firewall | Run the devcontainer itself behind an egress filter if you need one |
| **Non-standard credential paths** | The installer scans `mount` and warns about `/kubeconfig`-style binds at install time, but cannot enumerate every custom mount | Audit your devcontainer's `mounts` block |
| **Non-root devcontainers; rootful Docker w/ default AppArmor** | v1 targets rootless podman + Debian/Ubuntu + `remoteUser=root` | Tracked for v2 |
