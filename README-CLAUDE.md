# Claude in a sandbox — threat model and verification

This document spells out the defences `claude-sandbox` enforces, what
is deliberately exposed, and how to verify the installation at any
time. Lives in the meta-repo for documentation; the install does NOT
copy it into your workspace (`cp <clone>/README-CLAUDE.md ./`
yourself if you want it locally).

## TL;DR

Each row maps a defence to the bwrap primitive that enforces it and
the `/verify-sandbox` check number that proves it. Run
`/verify-sandbox` from inside Claude to execute the full battery (18
PASS/FAIL checks + 10 adversarial breakout probes; the command exits
non-zero on any FAIL, so it's usable as a CI assertion).

| Defence | bwrap primitive | Verify |
|---|---|---|
| Sandbox is actually entered | `IS_SANDBOX=1` sentinel | check 01 |
| Setuid escalation blocked | `NO_NEW_PRIVS` (set by bwrap before exec) | check 02 |
| Strict-under-`/root` by inversion | `--tmpfs /root` then re-bind `.claude` / `.claude.json` / `.cache` / `.config/{gh,glab-cli}` / `.local/share` (with `applications/` + `claude/` tmpfs-masked) | check 03 |
| Host env vars scrubbed | `--clearenv` + explicit allow-list | checks 04, 05 |
| Zero capabilities | `--cap-drop ALL` | check 06 |
| PID namespace (kill/ptrace scoping) | `--unshare-pid` | check 07 |
| SysV IPC namespace | `--unshare-ipc` | check 08 |
| UTS namespace | `--unshare-uts` | check 09 |
| TIOCSTI terminal injection blocked | `--dev /dev` + `script(1)` pty wrap | check 10 |
| VS Code IPC bridges masked | `--tmpfs /tmp` | check 11 |
| User runtime dir masked | `--tmpfs /run/user` | check 12 |
| Docker/Compose secrets masked | `--tmpfs /run/secrets` | check 13 |
| `.netrc` defence in depth | `--bind-try /dev/null /root/.netrc` | check 14 |
| `.Xauthority` defence in depth | `--bind-try /dev/null /root/.Xauthority` | check 15 |
| Curated gitconfig in effect | `GIT_CONFIG_GLOBAL=/etc/claude-gitconfig`, `GIT_CONFIG_SYSTEM=/dev/null` | check 16 |
| Chrome browser-extension RPC channel disabled | shadow injects `--no-chrome` and strips user `--chrome` so Claude Code never writes its `NativeMessagingHosts` manifest | check 03 (regression manifests as browser dirs under `~/.config`) |

Network egress (`--share-net`, NOT unshared) is deliberately open so
Claude can reach `api.anthropic.com`. No PASS/FAIL check — any
regression makes Claude fail on first use rather than silently.
Implicit: `--die-with-parent` (the sandbox disappears the moment
Claude does).

**Refusal-on-failure**: if the host can't run unprivileged user
namespaces, the installer refuses with a specific actionable
diagnostic. Silent degradation to "Claude installed but not
sandboxed" is itself a UX failure mode that gets people pwned.

## Threat model

**Defending against:** a developer running Claude Code inside a
devcontainer against an LLM-driven attack — a hostile prompt, a
hostile file Claude reads, or a hostile tool result — attempting to
exfiltrate host credentials, drive the host IDE, or escalate
privileges.

### In scope

The TL;DR table above. Each row corresponds to one observed
exfiltration path (env vars, dotfiles, IPC sockets, X11, TIOCSTI,
sudo, …) and the primitive that closes it.

### Out of scope

| Exposure | Why | Mitigation expected from you |
|---|---|---|
| **Workspace contents** | Claude has to read your workspace to do its job | Keep secrets outside the workspace (e.g. `~/.config/` mounted via your devcontainer's `mounts`). Don't put `.env` files with production credentials at the workspace root and expect them to be invisible |
| **Container host kernel** | A bwrap-aware kernel exploit is out of scope; this is a credential-isolation tool, not a sandbox against arbitrary native code | Keep your kernel patched; treat the devcontainer host as the trust boundary |
| **Network egress filtering** | Claude needs network. The sandbox shares the netns and does not run a per-process firewall | Run the devcontainer itself behind an egress filter if you need one |
| **Non-standard credential paths** | The installer scans `mount` and warns about `/kubeconfig`-style binds at install time, but cannot enumerate every custom mount | Audit your devcontainer's `mounts` block |
| **Non-root devcontainers; rootful Docker w/ default AppArmor** | v1 targets rootless podman + Debian/Ubuntu + `remoteUser=root` | Tracked for v2 |

## Deliberately exposed

Anything not in the lockdown list above is reachable from inside
Claude. The deliberate exposures:

| Path | Mode | Why |
|---|---|---|
| Workspace | rw | The whole point of Claude — see [workspace visibility caveat](#workspace-visibility-caveat) below. Default: `$PWD` (only the current project is writable). Override: set `CLAUDE_SANDBOX_WORKSPACE_ROOT=/workspaces` in `remoteEnv` to restore the old broad bind and make sibling devcontainer projects writable. Extra paths: `allow-write = <abs-path>` lines in `/etc/claude-sandbox.conf` (one path per line; blank lines and `#` comments ignored) |
| `/etc/claude-sandbox.conf` | r | Host-global sandbox config (`workspace-root`, `no-forge`, `allow-write`), placed by `install.sh` from the clone's `.devcontainer/claude-sandbox.conf` and read by the shadow at launch. Lives at `/etc`, **not** in the rw-bound workspace, so a compromised session can't rewrite it to widen the next launch's binds. Edit the clone conf + re-run `./install` (a rebuild does it via postCreate) to change it |
| `/etc/claude-gitconfig` | r | Curated gitconfig: gh/glab credential helpers for `https://github.com` and `https://gitlab.diamond.ac.uk`, ssh→https `insteadOf` rewrites, regenerated at every shadow launch from your host's current `user.name`/`user.email` |
| `/etc/gitconfig` | r | Host's system gitconfig is reachable read-only but neutralised for `git` because `GIT_CONFIG_SYSTEM=/dev/null` — see [gitconfig defence-in-depth](#gitconfig-defence-in-depth) |
| `/root/.claude/` | rw | Claude's state, settings, skills, hooks. `install.sh` symlinks this to `/user-terminal-config/.claude` so the tree persists across rebuilds and is shared with every other devcontainer that mounts the same `terminal-config` dir |
| `/root/.claude.json` | rw | Account-level state (OAuth token, recent-projects list, settings). Symlinked alongside `~/.claude/`; without it the strict-under-/root tmpfs would swallow the token and re-prompt login every launch |
| `/root/.cache/` | rw | Tool caches Claude needs across runs (if present) |
| `/root/.config/gh/` | rw | `gh` CLI's token store. Required so `gh auth status` works and the curated gitconfig's `gh auth git-credential` helper can authenticate `git push` to GitHub without an OAuth popup |
| `/root/.config/glab-cli/` | rw | `glab` CLI's token store. Same reason as `gh`. Sibling paths under `/root/.config/` (VS Code state, other cred helpers, etc.) are NOT bound |
| `/root/.local/share/` + single files `/root/.local/bin/{uv,uvx}` | rw | Bulk-bound XDG data dir: host-installed plugins for `helm`, `kubectl`/`krew`, `uv`-managed Python, etc. just work inside the sandbox without per-tool allowlist additions. `applications/` and `claude/` are tmpfs-masked so Claude Code's own writes (URL handler `.desktop`, versioned binary cache) stay ephemeral. `.config/` stays strict-allowlist — credentials live there, not under `.local/share/`. See [XDG split rationale](#xdg-split-rationale) and [uv bind discipline](#uv-bind-discipline) |
| `/usr/libexec/claude-sandbox/claude` | r | The real Claude binary, relocated here by the installer from `~/.local/bin/claude` so plain `claude` on the user's PATH always resolves to the shadow. The shadow exec's this same file via `bwrap`; a bind back to `~/.local/bin/claude` inside the sandbox keeps Claude Code's `installMethod=native` self-check happy |
| Network (`--share-net`) | — | Claude needs `api.anthropic.com` + GitHub/GitLab. See [network-identity disclosure](#network-identity-disclosure) |

### Workspace visibility caveat

Workspace contents are visible to Claude — this is irreducible.
Claude has to read your workspace to do its job. The sandbox
protects you against host-credential leaks via env vars, dotfiles,
and IPC sockets, but **anything you check out into your workspace is
by design reachable from Claude's tools**.

Practical rule: keep secrets outside the workspace (e.g., in
`~/.config/` mounted via your devcontainer's `mounts`). Don't put
`.env` files with production credentials at the workspace root and
expect them to be invisible.

<details>
<summary id="xdg-split-rationale">XDG split rationale: data bulk-bound, config strict-allowlist</summary>

The bind-back list splits by XDG category. `$HOME/.config/` keeps the
strict allowlist (`gh`, `glab-cli` and that's it) because credentials
live here by XDG contract — `gcloud`, `helm` repo auth, `gh` tokens,
`oauth2-proxy` cookies, anything secret a tool persists. A new
credentialed tool that drops files under `$HOME/.config/<newtool>/`
is masked for free.

`$HOME/.local/share/` and `$HOME/.cache/` go the other way and are
bulk-bound. These are XDG data/cache locations — plugin trees,
binary registries, download caches, etc. Bulk-binding them means
host-installed `helm` plugins, `kubectl`/`krew` plugins, `cargo`
registry, `npm` global state, `uv`-managed Pythons, and so on are
visible inside the sandbox without each requiring an allowlist
addition. The forward-compat bet is on XDG discipline: a tool that
stores credentials under `~/.local/share/<tool>/` instead of
`~/.config/<tool>/` would leak. Audit when adding such a tool.

Two sub-dirs under `.local/share/` are tmpfs-masked so Claude Code's
own runtime writes don't escape into the host:

- `applications/` — Claude Code drops a `.desktop` URL handler here
  on first launch. Binding the host's dir would register our
  in-sandbox claude as a URL handler in the host desktop
  environment.
- `claude/` — Claude Code's own versioned binary cache, designed to
  be ephemeral; binding the host's would collide with the host's
  `claude` install.

`.local/state/` and `.local/bin/` stay tmpfs by default. State is
transient by XDG contract; `.local/bin/` is appended-not-prepended on
PATH and selectively binds only `uv`/`uvx`/the real `claude` (see
[uv bind discipline](#uv-bind-discipline)).

Dotdir credential stores that pre-date XDG (`.ssh`, `.aws`, `.gnupg`,
`.docker`, `.kube`, `.azure`, etc.) sit directly under `$HOME` and
are masked by the `--tmpfs $HOME` baseline — the inversion is still
in effect at the top level; only `.config/`, `.local/share/`, and
`.cache/` change polarity.

</details>

<details>
<summary id="uv-bind-discipline">uv bind discipline</summary>

The whole `~/.local/bin/` directory is NOT bound — Claude Code
writes there via tmpfs at runtime and we want those writes
ephemeral. Only `uv` and `uvx` individually. `$HOME/.local/bin` is
appended to PATH so `uv` resolves without a full path; **appended,
not prepended**, so a malicious binary in `~/.local/bin/<sysname>`
cannot hijack a standard command.

</details>

<details>
<summary id="gitconfig-defence-in-depth">gitconfig defence-in-depth</summary>

Tools that scrub `GIT_*` env vars before spawning git (e.g.
pre-commit's `no_git_env`) will see the host `/etc/gitconfig`, which
is the intended behaviour — the defence-in-depth bind-mask we
previously layered here broke those tools without adding meaningful
protection beyond the env redirect. The host's `/root/.gitconfig` is
invisible via strict-under-/root, so there is no comparable concern
at $HOME.

</details>

<details>
<summary id="network-identity-disclosure">Network-identity disclosure</summary>

Because the network namespace is shared with the host, Claude can
enumerate the host's interface addresses, routing table, and DNS
resolver via `AF_NETLINK` / standard tooling (`ip addr`, `ip
route`, `/etc/resolv.conf`). This is network-identity disclosure,
not credential exfil — but it means the sandbox is visible to
internal services on the same host network. Don't run a local
metadata-style credential service on the loopback or RFC1918 of a
host that also runs `claude` unless you're OK with Claude reaching
it. `/verify-sandbox` flags this as an `[INCONCLUSIVE]` adversarial
probe so it stays on the radar.

</details>

<details>
<summary id="procfs-view">Procfs view: host PIDs are visible (accepted info-disclosure)</summary>

`--unshare-pid` reliably gives kernel-level pidns isolation (the
sandbox cannot `kill()` or `ptrace()` host or devcontainer processes
— check 07 verifies this via `/proc/self/status:NSpid:`). The
companion property — `/proc` reflecting *only* the sandbox's own
process tree — depends on bwrap successfully mounting procfs against
the new pidns, which fails on rootless nested-userns hosts (the
standard VS Code devcontainer pattern).

`claude-sandbox` always emits `--ro-bind /proc /proc` rather than
probing. Host PIDs are enumerable from inside the sandbox. This is
**information disclosure** (Claude can see the user's process tree
and command lines), **not credential exfil**. The credential-bearing
procfs entries — `/proc/<pid>/environ`, `/maps`, `/fd`, `/mem`,
`/cwd` — are gated by `PTRACE_MODE_READ_FSCREDS`, which under YAMA
`ptrace_scope=1` (the Ubuntu/Debian default and what every
devcontainer base image ships) is restricted to the caller's
descendants. The sandbox has no descendant relationship with VS
Code, terminal sessions, or other devcontainer processes, so those
reads `EACCES`. Check 07 still passes — kernel pidns isolation is
intact.

</details>

## PAT hygiene

`gh` and `glab` store personal access tokens in `~/.config/gh/` and
`~/.config/glab-cli/`, which are bound rw into the sandbox so Claude
can push code. A compromised session could use those tokens to push to
any repository the PAT covers, modify CI workflows, or reach other
repos in the same organisation.

**Recommended PAT shape:**

- **Fine-grained token, single repo** — GitHub: Settings → Developer
  settings → Fine-grained tokens. Grant write access only to the
  repository you're actively working on.
- **Short expiry** — 7–30 days. `just gh-auth` re-pastes in seconds.
- **No `workflow` scope** unless Claude needs to modify GitHub Actions
  files. No `admin:*` or org-wide write scopes.
- **GitLab**: equivalent fine-grained project tokens, `api` scope only
  if you need push; `read_repository` + `write_repository` otherwise.

`just gh-auth` / `just glab-auth` keep the token out of shell history
but do not enforce scope discipline — that's yours.

### `CLAUDE_SANDBOX_NO_FORGE=1`

If Claude doesn't need to push code in a given session, set this in
your devcontainer's `remoteEnv` to skip the `gh`/`glab` token binds
entirely. The credential helpers are also removed from the generated
gitconfig, so `git push` will fail inside the sandbox — intentionally.

```jsonc
// .devcontainer/devcontainer.json → remoteEnv
"CLAUDE_SANDBOX_NO_FORGE": "1"
```

Restart (or rebuild) the devcontainer for the change to take effect.
A commented-out example is included in this repo's `devcontainer.json`.

## Verifying

```
/verify-sandbox        # inside Claude
```

Runs the 18 PASS/FAIL checks against the live process and prints a
summary table. Any FAIL exits the command non-zero (so you can use
it as a CI assertion), and the FAIL line names which defence
regressed. The full spec lives at
`.claude/commands/verify-sandbox.md`.

A **global integrity guard**, delivered through Claude Code's
highest-precedence **managed-settings** layer
(`/etc/claude-code/managed-settings.json`), runs in every folder (even
ones with no project `.claude/`) and **cannot be removed by editing
`~/.claude/settings.json`**:

- `SessionStart` → `/usr/libexec/claude-sandbox/sandbox-verify.sh` runs
  the full integrity subset once per session and warns loudly (it
  cannot block — SessionStart hooks only inject messages/context) when
  Claude is running outside the shadow.
- `UserPromptSubmit` → `/usr/libexec/claude-sandbox/sandbox-gate.sh` is
  a sub-second fail-closed gate: it blocks every prompt unless
  `IS_SANDBOX=1`. Set `CLAUDE_SANDBOX_ALLOW_UNWRAPPED=1` to downgrade to
  warn-only. Both skip on Claude Code Web (`CLAUDE_CODE_REMOTE=true`).

The hook entries (in `/etc`) and the scripts (in `/usr/libexec`) both
sit outside the sandbox's rw set and outside the user-editable
`~/.claude`, so neither a compromised in-session Claude nor an
accidental settings edit can disable them. See [Keeping the shadow on
PATH](./README.md#keeping-the-shadow-on-path) for why this lives in the
managed layer and why the installer disables the auto-updater.

## What's installed

Container-scoped — re-established by re-running `./install`,
typically wired into `postCreate.sh`:

| Path | Source | Purpose |
|---|---|---|
| `/usr/libexec/claude-sandbox/claude` | Anthropic installer (`curl -fsSL https://claude.ai/install.sh \| bash`), relocated | The real Claude binary, kept off the user's PATH so the shadow always wins |
| `/usr/local/bin/claude` | `.devcontainer/claude-sandbox/claude-shadow` (verbatim) | Shadow that wraps the real binary in `bwrap`. Falls through to the real binary when `IS_SANDBOX=1` so internal `claude` invocations from a hook don't recurse |
| `/etc/claude-gitconfig` | Generated | Curated gitconfig — regenerated from `git config --get user.{name,email}` on every shadow launch |
| `/usr/libexec/claude-sandbox/sandbox-verify.sh` | `SessionStart` guard script — full integrity battery + loud warn when unwrapped. Off-PATH, root-owned, ro inside the sandbox |
| `/usr/libexec/claude-sandbox/sandbox-gate.sh` | `UserPromptSubmit` guard script — sub-second fail-closed gate (`IS_SANDBOX=1` or block). Same protections |
| `/etc/claude-code/managed-settings.json` | The GLOBAL guard policy. jq-merged idempotently: adds the two hooks (deduped by basename), sets `env.DISABLE_AUTOUPDATER=1` + `autoUpdates:false`. Highest-precedence + user-uneditable, so removing the hooks from `~/.claude/settings.json` does **not** disable the guard. Any real admin policy already in the file is preserved; `allowManagedHooksOnly` is deliberately **not** set (your own hooks still run) |

Disabling the auto-updater is **root-cause removal**: Claude Code's
updater otherwise re-creates `~/.local/bin/claude` on a version bump,
which can launch the real binary unwrapped and self-entrench. With the
updater off, updates happen only via a deliberate `./install`, which
re-relocates the current binary and re-asserts the shadow.

User-scope `~/.claude` (preference only — the guard does **not** live
here):

| Path | Behaviour |
|---|---|
| `~/.claude/statusline-command.sh` | Statusline — seeded **only if absent** (an owner-customised one survives) |
| `~/.claude/settings.json` | `.statusLine` set only if absent; otherwise untouched. If an earlier install put the guard here, those hook entries are pruned so the guard has a single authoritative home (`/etc`). All other keys — yours — preserved |

Not placed: `CLAUDE.md` and `README-CLAUDE.md` live in the meta-repo
for dogfooding.

## Running it

```
claude
```

The shadow on `$PATH` always wraps; you cannot accidentally run the
unwrapped binary from your normal shell. The curated gitconfig is
regenerated from the host's current `user.name`/`user.email` on
every launch, so a host gitconfig edit takes effect on the next
`claude` invocation with nothing to re-run.

## Authenticating

```
just gh-auth                    # github.com
just glab-auth                  # gitlab.com
just glab-auth gitlab.diamond.ac.uk
```

Both walk you through a fine-grained-PAT prompt without leaking the
token into shell history.
