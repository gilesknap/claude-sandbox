# Architecture

## At a glance

`claude-sandbox` is a launch-time wrapper. A **shadow** `claude` sits first
on `$PATH` at `/usr/local/bin/claude`; the real Anthropic binary is
**relocated off-PATH** to `/usr/libexec/claude-sandbox/claude`. Every plain
`claude` invocation therefore resolves to the shadow, which re-execs the real
binary inside a `bwrap` jail. Inside that jail the filesystem is mounted
read-only and `$HOME` is wiped to a `tmpfs`, so host credentials, IDE bridges,
and the shell environment are unreachable — while the current workspace stays
read-write and the network stays open, because Claude needs both to work. A
separate **integrity guard**, delivered through Claude Code's highest-precedence
managed-settings layer, fires in every folder and fails loud (and closed) if
Claude is ever launched outside the shadow.

## Design philosophy

Five ideas run through the whole system, and every file below is an expression
of one of them:

- **Small enough to audit in one read.** It is Bash, not a package. The shadow
  is a single file you can read top-to-bottom; the `bwrap` argv builder is
  inlined, not sourced from elsewhere.
- **Default-deny by inversion.** The base mount is `--ro-bind / /` and `$HOME`
  is a `tmpfs`; access is granted by an explicit short bind-back list. Anything
  not enumerated stays masked.
- **`/etc`, never the workspace.** Config and policy that govern the *next*
  launch live under `/etc` (outside the read-write workspace), so a compromised
  session cannot rewrite them to widen its own binds.
- **Tamper-resistant guard.** The guard's policy lives in managed settings
  (un-removable by editing your own `~/.claude`) and its scripts live off-PATH,
  read-only inside the sandbox.
- **Refusal over silent degradation.** If unprivileged user namespaces are
  forbidden, the installer refuses rather than install a non-functional sandbox.

For the full inventory of what is locked down vs. deliberately exposed, see the
[threat model](threat-model.md). This page is the *map* — how the pieces fit.

## 1. System context

The trust boundary is the edge of the `bwrap` jail. Outside it sit everything an
LLM-driven attack would want: host dotfiles and the host gitconfig, the host
environment, `/run/secrets`, the VS Code IPC sockets in `/tmp`, X11/runtime
sockets. The shadow on `$PATH` is the only doorway, and it constructs the jail
so those things land on the outside. Two exposures are deliberately *inside*:
the workspace (`$PWD`, read-write) and the network.

```{mermaid}
graph TB
    user["developer shell<br/>types: claude"]

    subgraph host["devcontainer host (trust boundary)"]
        direction TB
        subgraph creds["OUTSIDE the jail — masked"]
            dotfiles["$HOME dotfiles<br/>.ssh .aws .gnupg .netrc"]
            hostenv["host env<br/>GH_TOKEN ANTHROPIC_API_KEY"]
            secrets["/run/secrets"]
            ipc["VS Code IPC sockets<br/>/tmp"]
            x11["X11 / /run/user"]
        end
        shadow["/usr/local/bin/claude<br/>(shadow, first on PATH)"]
        real["/usr/libexec/claude-sandbox/claude<br/>(real binary, off-PATH)"]
    end

    subgraph jail["bwrap jail (IS_SANDBOX=1)"]
        direction TB
        ro["--ro-bind / /<br/>--tmpfs $HOME"]
        ws["workspace $PWD (rw)<br/>deliberate exposure"]
        net["--share-net<br/>api.anthropic.com, GitHub/GitLab"]
    end

    user --> shadow
    shadow -->|bwrap argv wrapped in script pty| jail
    jail -->|exec ~/.local/bin/claude| real
    creds -.->|excluded| jail
```

The shadow never lets the real binary run unwrapped from a normal shell: because
the real binary is relocated off `$HOME/.local/bin`, plain `claude` cannot
resolve past the shadow. (Anthropic's installer drops the binary at
`~/.local/bin/claude` and prepends that dir to your shell rc; relocating the
binary makes that rc-mutation inert.) The dashed line shows the credential set
being *excluded* from the jail, not bound into it.

## 2. Launch sequence

A plain `claude` triggers the shadow, which does three host-side reads
(regenerate the gitconfig from your live git identity, read the `/etc` config,
build the argv), then execs `bwrap` wrapped in `script(1)`. The `script(1)` wrap
allocates a fresh pseudo-terminal — that is the TIOCSTI defence: an `ioctl`
inside the sandbox lands in `script`'s pty, which reads it back as bytes, not
keystrokes, to the host terminal.

A nested `claude` invocation (a hook or skill spawning `claude` *inside* the
jail, where `IS_SANDBOX=1` is already set) must not re-wrap. The recursion guard
at the top of the shadow handles this: it execs the real binary directly.

```{mermaid}
sequenceDiagram
    autonumber
    participant U as shell
    participant S as shadow<br/>/usr/local/bin/claude
    participant FS as host /etc
    participant B as bwrap + script(1)
    participant R as real claude<br/>~/.local/bin/claude (in jail)

    U->>S: claude [args]
    alt IS_SANDBOX=1 (nested call inside jail)
        S->>R: exec ~/.local/bin/claude --no-chrome (no re-wrap)
    else normal launch from host shell
        S->>S: touch ~/.claude.json (bind-back target)
        S->>FS: regenerate /etc/claude-gitconfig<br/>from host user.name / user.email
        S->>FS: parse_config /etc/claude-sandbox.conf
        S->>S: resolve_workspace_root ($PWD or override)
        S->>S: bwrap_argv_build(workspace, real, args)
        S->>B: exec script -q -c [bwrap argv] /dev/null
        B->>R: exec --no-chrome [args] with IS_SANDBOX=1
    end
```

The gitconfig is regenerated on *every* launch, not just at install: VS Code's
`copyGitConfig` runs after `postCreate`, so an install-time render could capture
an empty `user.name`. Re-rendering at launch means a host gitconfig edit takes
effect on the next `claude` with nothing to re-run. The shadow also injects
`--no-chrome` and strips any user `--chrome` on both paths, so Claude Code never
writes its browser-extension native-messaging manifest.

## 3. Filesystem inversion

This is the core security idea. The sandbox does not enumerate what to hide; it
hides everything by default and enumerates the short list of what to *show*. The
base is `--ro-bind / /`. On top of that, `$HOME`, `/tmp`, and (when the host has
them) `/run/user` and `/run/secrets` become `tmpfs` — wiped, empty. Then a
single bind-back list restores exactly what Claude legitimately needs under
`$HOME`, split by XDG category.

```{mermaid}
graph TD
    base["--ro-bind / /<br/>read-only base"]
    base --> tmpfs

    subgraph tmpfs["tmpfs masks (wiped)"]
        h["$HOME"]
        t["/tmp"]
        ru["/run/user *"]
        rs["/run/secrets *"]
    end

    h --> bindback

    subgraph bindback["bind-back under $HOME (allow-list)"]
        direction TB
        claude[".claude · .claude.json"]
        cache[".cache"]
        forge[".config/gh · .config/glab-cli"]
        share[".local/share<br/>helm · krew · uv"]
        uv[".local/bin/uv · uvx"]
        realbin["real claude"]
    end

    share --> masked

    subgraph masked["re-masked (ephemeral)"]
        apps[".local/share/applications"]
        ccache[".local/share/claude"]
    end

    subgraph nullmask["bound to /dev/null"]
        netrc[".netrc<br/>.Xauthority<br/>.ICEauthority"]
    end

    h -.-> nullmask
```

`*` `/run/user` and `/run/secrets` masks are emitted only when the host has the
source directory — `bwrap` cannot `mkdir` into a read-only `/run` that lacks the
subdir (the GitHub Actions `ubuntu-24.04` runner case).

The split is the subtle part. `$HOME/.config/` stays a **strict allow-list**
(`gh`, `glab-cli`, nothing else) because by XDG contract credentials live there
— a new credentialed tool dropping files under `.config/<tool>/` is masked for
free. `$HOME/.local/share/` and `.cache/` go the other way and are **bulk-bound**
so host-installed plugin and data trees just work; two sub-dirs Claude Code
writes itself (`applications/` for a `.desktop` URL handler, `claude/` for its
versioned binary cache) are re-masked with `tmpfs` so those writes stay
ephemeral. The `.netrc` / `.Xauthority` / `.ICEauthority` masks are
belt-and-braces: `--tmpfs $HOME` already hides them, but binding `/dev/null`
over them survives if that baseline ever regresses. The rationale for the XDG
polarity split is in the [threat model](threat-model.md); the exact bind list is
in the [reference](../explanations/sandbox-internals.md).

## 4. Integrity guard

The filesystem inversion only protects you if Claude actually entered the jail.
The guard defends the *launch path itself*. Its failure mode is the auto-updater
re-creating `~/.local/bin/claude` and launching the real binary unwrapped — this
happened in practice and silently disabled the sandbox for days. The guard
closes it with both a root-cause fix and a fail-loud safety net, and crucially
puts both somewhere a user cannot accidentally edit away.

```{mermaid}
graph TD
    subgraph precedence["settings precedence (highest wins)"]
        direction TB
        managed["/etc/claude-code/managed-settings.json<br/>HIGHEST · un-removable by user"]
        userset["~/.claude/settings.json<br/>(user-editable · cannot override managed)"]
        managed -.->|outranks| userset
    end

    managed --> ss["SessionStart →<br/>bash /usr/libexec/claude-sandbox/sandbox-verify.sh"]
    managed --> ups["UserPromptSubmit →<br/>bash /usr/libexec/claude-sandbox/sandbox-gate.sh"]
    managed --> upd["env.DISABLE_AUTOUPDATER=1<br/>autoUpdates=false"]

    ss --> ssact["full integrity battery once/session<br/>WARN loudly if IS_SANDBOX unset<br/>(cannot block)"]
    ups --> upsact{"IS_SANDBOX=1 ?"}
    upsact -->|yes| pass["exit 0 — prompt proceeds"]
    upsact -->|no| block["exit 2 — BLOCK every prompt<br/>(unless ALLOW_UNWRAPPED=1)"]
    upd --> noarm["updater can't re-arm the bypass"]
```

Three things work together. **`DISABLE_AUTOUPDATER=1` + `autoUpdates=false`** is
the root-cause removal: updates now only happen when *you* re-run `./install`,
which re-relocates the binary and re-asserts the shadow. **`sandbox-verify.sh`**
(`SessionStart`) runs the full battery and warns loudly when unwrapped — but
`SessionStart` hooks can only inject messages, never block. **`sandbox-gate.sh`**
(`UserPromptSubmit`) is the one mechanism that can actually stop work: a
sub-second `IS_SANDBOX=1` string compare that `exit 2`s (blocks) every prompt
otherwise. Both skip on Claude Code Web (`CLAUDE_CODE_REMOTE=true`), and
`CLAUDE_SANDBOX_ALLOW_UNWRAPPED=1` downgrades the gate to warn-only.

Why a user editing `~/.claude/settings.json` cannot disable it: the hook
*entries* live in the managed-settings layer, which outranks user settings and
is only writable by `root` (or a deliberate `./install`). The hook *scripts*
live in `/usr/libexec/claude-sandbox/` — root-owned, off-PATH, and read-only
inside the sandbox (`--ro-bind / /`), so even a compromised in-session Claude
cannot rewrite them to `exit 0`. The installer merges the policy in
idempotently, preserves any real enterprise admin policy already present, and
deliberately does **not** set `allowManagedHooksOnly`, so your own hooks still
run. The full guard mechanics are in [integrity guard](integrity-guard.md).

## 5. Config trust flow

The sandbox config (`workspace-root`, `no-forge`, `allow-write`) follows the
same `/etc`-not-the-workspace discipline as the guard, and for the same reason.
You edit the conf in the clone; `install.sh` copies it to `/etc`; the shadow
reads it from `/etc` at launch — never from `$PWD`.

```{mermaid}
graph LR
    clone[".devcontainer/claude-sandbox.conf<br/>(in the clone — you edit here)"]
    etc["/etc/claude-sandbox.conf<br/>(host-global, outside the rw workspace)"]
    shadow["shadow at launch<br/>parse_config()"]
    argv["bwrap argv<br/>WORKSPACE_ROOT, ALLOW_WRITE, NO_FORGE"]

    clone -->|install.sh install_conf<br/>re-stamped each rebuild| etc
    etc -->|read at launch| shadow
    shadow --> argv

    pwd["$PWD (rw workspace)<br/>compromised session can write here"]
    pwd -. NOT read for config .-> shadow
```

This closes a cross-session bind-escalation vector. If the shadow read its
config from the workspace, a compromised session could append
`allow-write = /some/sensitive/path` and the *next* launch would widen its own
binds. Reading exclusively from `/etc` — which the in-jail Claude sees only
read-only — means a session can never escalate the binds of a future session.
The config keys themselves are documented in
[configuration](../reference/configuration.md).

## 6. The promote three-layer model

Installing into the source clone is one thing; making an *arbitrary* workspace a
self-sufficient claude-sandbox host is `just promote`. It lands three layers in
the target so a teammate who clones it only needs the devcontainer to come up.
Notably, promote does **not** seed the integrity guard per-repo — the guard is
global, wired into `/etc` by `install.sh` (which the target's `postCreate` runs),
so promote never touches the target's project `settings.json`, hooks, or
statusline.

```{mermaid}
graph TD
    src["source clone<br/>.claude/ + .devcontainer/claude-sandbox/"]

    src -->|just promote TARGET| target

    subgraph target["target workspace"]
        direction TB
        l1["Layer 1 — curated .claude/<br/>commands/ + skills/ (no hooks/settings)"]
        l2["Layer 2 — install machinery<br/>.devcontainer/claude-sandbox/{install.sh,<br/>claude-shadow, promote.sh,<br/>sandbox-verify.sh, sandbox-gate.sh}<br/>+ justfile, claude-sandbox.conf (if absent)"]
        l3[".devcontainer/postCreate.sh<br/>→ bash .devcontainer/claude-sandbox/install.sh"]
    end

    l3 -->|on devcontainer create| installs["install.sh wires the<br/>GLOBAL guard into /etc + /usr/libexec"]

    target -->|printed to stderr, NOT auto-edited| snippet["paste into devcontainer.json:<br/>postCreateCommand → .devcontainer/postCreate.sh"]
```

The root `install` shim is *not* copied — it is the source repo's manual-UX
entry, and promoted targets invoke `install.sh` from `postCreate.sh` directly.
The final step is deliberately *not* automated: promote prints the
`postCreateCommand` snippet to paste into `devcontainer.json` rather than editing
it, because that file is JSONC in the wild (comment-preserving structured edits
are more code than this repo wants) and only you know whether you have already
wired it or need to combine it with an existing command. Promote is idempotent,
refuses to target the clone itself, and never touches `~/.claude` — that channel
is reserved for cross-container shared state (OAuth, memories). The step-by-step
recipe is in the [how-to guide](../how-to.md).

## Where the code lives

| Concern | File |
|---|---|
| Shadow + inlined `bwrap` argv builder, recursion guard, gitconfig render, `script(1)` wrap | `.devcontainer/claude-sandbox/claude-shadow` |
| Relocate real binary off-PATH; wire shadow; merge managed-settings guard; disable auto-updater; place `/etc` config | `.devcontainer/claude-sandbox/install.sh` |
| Three-layer promote into a target workspace | `.devcontainer/claude-sandbox/promote.sh` |
| `SessionStart` guard — full integrity battery + loud warn when unwrapped | `.devcontainer/claude-sandbox/sandbox-verify.sh` |
| `UserPromptSubmit` guard — sub-second fail-closed `IS_SANDBOX` gate | `.devcontainer/claude-sandbox/sandbox-gate.sh` |
| Integrity-battery spec (18 checks + 10 adversarial probes) | `.claude/commands/verify-sandbox.md` |
| Tests CI runs (argv builder, smoke, promote) | `tests/bwrap_argv.sh`, `tests/smoke.sh`, `tests/promote.sh` |

### See also

- [Threat model](threat-model.md) — what is locked down, what is deliberately exposed, and why.
- [Integrity guard](integrity-guard.md) — the managed-settings guard and the unwrapped-launch bypass it closes.
- [Sandbox internals](../explanations/sandbox-internals.md) — the exact `bwrap` flags and bind list.
- [Configuration](../reference/configuration.md) — `/etc/claude-sandbox.conf` keys and env-var overrides.
- The four sections: [tutorials](../tutorials.md), [how-to](../how-to.md), [reference](../reference.md), [explanations](../explanations.md).
