# Sandbox internals: design rationale

This page explains *why* several of the sandbox's more subtle binds and
masks are shaped the way they are. It assumes you already know the
shape of the sandbox from the [threat model](threat-model.md) and the
list of [deliberately-exposed paths](../reference/deliberately-exposed.md);
here we cover the reasoning behind five decisions where the obvious
implementation would have been wrong or leaky.

The baseline is *strict-under-`$HOME` by inversion*: the shadow emits
`--tmpfs $HOME` to wipe the home directory, then binds back only what
Claude legitimately needs. Anything not enumerated stays masked. The
rationale below is mostly about *which* things are bound back, and how.

## The XDG split: data bulk-bound, config strict-allowlist

The bind-back list does not treat `$HOME` uniformly — it splits by XDG
category, and the two halves have opposite polarity on purpose.

`$HOME/.config/` keeps a **strict allowlist**: `gh`, `glab-cli`, and
nothing else. Credentials live here by XDG contract — `gcloud`,
`helm` repo auth, `gh` tokens, `oauth2-proxy` cookies, and anything
secret a tool persists. Keeping `.config/` masked-by-default means a
new credentialed tool that drops files under
`$HOME/.config/<newtool>/` is hidden for free, with no allowlist edit
required. The forge token dirs are the only exceptions because Claude
needs them to push code, and they are skipped entirely under
`CLAUDE_SANDBOX_NO_FORGE=1`.

`$HOME/.local/share/` and `$HOME/.cache/` go the other way and are
**bulk-bound**. These are XDG data and cache locations — plugin trees,
binary registries, download caches. Bulk-binding them means
host-installed `helm` plugins, `kubectl`/`krew` plugins, the `cargo`
registry, `npm` global state, `uv`-managed Pythons, and similar all
appear inside the sandbox without each requiring an allowlist
addition. The forward-compat bet is explicit: it rests on XDG
discipline. A tool that stores credentials under
`~/.local/share/<tool>/` instead of `~/.config/<tool>/` would leak
them into the sandbox. Audit when you add such a tool.

Two sub-directories under `.local/share/` are re-masked with a tmpfs
overlay so Claude Code's *own* runtime writes stay ephemeral rather
than escaping onto the host:

- `applications/` — Claude Code drops a `.desktop` URL handler here on
  first launch. Binding the host's directory would register the
  in-sandbox `claude` as a URL handler in the host desktop
  environment.
- `claude/` — Claude Code's own versioned binary cache, designed to be
  ephemeral. Binding the host's would collide with the host's `claude`
  install.

`.local/state/` and `.local/bin/` are left as tmpfs. State is
transient by XDG contract, and `.local/bin/` is handled specially —
see [uv bind discipline](#uv-bind-discipline) below.

Pre-XDG dotdir credential stores (`.ssh`, `.aws`, `.gnupg`,
`.docker`, `.kube`, `.azure`, and so on) sit directly under `$HOME`
and are masked by the `--tmpfs $HOME` baseline. The inversion is still
fully in effect at the top level; only `.config/`, `.local/share/`,
and `.cache/` change polarity within it.

## uv bind discipline

The whole `~/.local/bin/` directory is deliberately **not** bound.
Claude Code writes into that directory via tmpfs at runtime, and those
writes are meant to be ephemeral. Only two individual files are bound
back — `uv` and `uvx` — so Python tooling installed via `uv` works
inside the sandbox. (The real `claude` binary is also bound into this
directory, at the conventional `~/.local/bin/claude` path, so Claude
Code's self-inspection sees the location it expects.)

For `uv` to resolve without a full path, `$HOME/.local/bin` is added
to `PATH`. The critical detail is that it is **appended, not
prepended**. PATH resolution scans left to right, so the system
directories (`/usr/local/bin`, `/usr/bin`, …) are searched first. A
malicious binary planted at `~/.local/bin/<sysname>` — for example a
fake `git` or `ls` — therefore cannot hijack a standard command,
because the genuine one in a system directory is found first. The same
appended-not-prepended discipline keeps the `/usr/local/bin/claude`
shadow winning resolution over anything in `~/.local/bin`.

## gitconfig defence-in-depth

The host's system gitconfig at `/etc/gitconfig` is reachable
read-only from inside the sandbox (it comes in via `--ro-bind / /`),
but it is **neutralised for `git`** by setting
`GIT_CONFIG_SYSTEM=/dev/null` in the sandbox environment, alongside
`GIT_CONFIG_GLOBAL=/etc/claude-gitconfig` which points git at the
curated config instead.

An earlier version layered an additional bind-mask over
`/etc/gitconfig` for defence-in-depth. That mask was **removed**. The
reason is that some tools scrub `GIT_*` environment variables before
spawning git — pre-commit's `no_git_env` is the canonical example.
Those tools will see the real host `/etc/gitconfig`, and that is the
*intended* behaviour. The bind-mask broke them without adding
meaningful protection beyond the environment redirect: the redirect
already covers every git invocation that inherits the sandbox
environment, and the tools that bypass the redirect are precisely the
ones that need the real system config. There is no comparable concern
for the per-user config: the host's `/root/.gitconfig` is invisible
under strict-under-`$HOME`, so nothing reaches it in the first place.

## Network-identity disclosure

The sandbox shares the host's network namespace (`--share-net`; the
netns is *not* unshared) because Claude needs to reach
`api.anthropic.com` and the forges. A consequence of the shared netns
is that Claude can enumerate the host's interface addresses, routing
table, and DNS resolver — via `AF_NETLINK` or ordinary tooling such as
`ip addr`, `ip route`, and reading `/etc/resolv.conf`.

This is **network-identity disclosure, not credential exfiltration**.
Nothing secret is leaked by it directly. But it does mean the sandbox
is visible to internal services on the same host network, and can
reach them. The practical caveat: do not run a local
metadata-style credential service on the loopback or RFC1918 address
of a host that also runs `claude`, unless you are comfortable with
Claude being able to reach it. `/verify-sandbox` surfaces this as an
`[INCONCLUSIVE]` adversarial probe so it stays on the radar rather
than being silently forgotten.

## The procfs view: host PIDs are visible

`--unshare-pid` reliably gives **kernel-level PID-namespace
isolation**: the sandbox cannot `kill()` or `ptrace()` host or
devcontainer processes. Check 07 verifies this directly via
`/proc/self/status:NSpid:`.

The companion property one might expect — `/proc` reflecting *only*
the sandbox's own process tree — is a different thing, and it does
*not* hold here. That property depends on bwrap successfully mounting a
fresh procfs against the new PID namespace, which fails on rootless
nested-userns hosts. That configuration is exactly the standard VS
Code devcontainer pattern, so rather than probe per-launch, the shadow
unconditionally emits `--ro-bind /proc /proc`. Host PIDs are therefore
enumerable from inside the sandbox.

This is an accepted **information disclosure** — Claude can see the
user's process tree and command lines — and explicitly **not**
credential exfiltration. The credential-bearing procfs entries
(`/proc/<pid>/environ`, `/maps`, `/fd`, `/mem`, `/cwd`) are gated by
the kernel's `PTRACE_MODE_READ_FSCREDS` check. Under YAMA
`ptrace_scope=1` — the Ubuntu/Debian default, shipped by every
devcontainer base image — that check restricts those reads to the
caller's own descendants. The sandbox has no descendant relationship
with VS Code, the terminal sessions, or other devcontainer processes,
so those reads return `EACCES`. The visibility of PIDs does not extend
to the contents that would matter, and check 07 still passes because
the kernel PID-namespace isolation is intact regardless.
