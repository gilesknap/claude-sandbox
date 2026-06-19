# The integrity guard

The whole protection is launch-time: plain `claude` must resolve to the
shadow at `/usr/local/bin/claude`, which `bwrap`-wraps the real binary
relocated to `/usr/libexec/claude-sandbox/claude`. This page explains the
one way that protection silently broke in practice, and the two-part fix
that makes the devcontainer safe-by-construction. For how the shadow,
relocation and bind mounts fit together, see
[architecture](architecture.md).

## The bypass risk

Claude Code's auto-updater re-creates `~/.local/bin/claude` on every
version bump. The official installer also prepends `~/.local/bin` to the
user's shell rc, so depending on `PATH` order a new shell can resolve
plain `claude` to that freshly-written copy — the *real* binary, launched
**unwrapped**: no `bwrap`, no `--clearenv` allow-list, no git steering.
Host credentials, env vars and dotfiles are no longer isolated.

The failure is self-entrenching and silent. Nothing warns you; the
session looks normal. This happened in practice — a self-update quietly
disabled the sandbox for days. Because the breach is *accidental* (an
updater re-arming the bypass, not an operator deliberately escaping), it
is exactly the class of failure this project's threat model aims to
catch.

## The two-part fix

### 1. Remove the root cause: disable the in-container updater

The installer sets `env.DISABLE_AUTOUPDATER=1` and `autoUpdates: false`
in the managed policy. With the in-container updater off, the thing that
re-creates `~/.local/bin/claude` never runs on its own. Updates become a
deliberate act: you re-run `./install`, which re-fetches the binary,
re-relocates it to `/usr/libexec/claude-sandbox/`, and re-asserts the
shadow. See [upgrade Claude Code](../how-to/upgrade.md) for that
workflow.

This is root-cause removal — the guard below is the backstop for if it
ever happens anyway.

### 2. Fail loud, and fail closed: the global guard

Two hooks, delivered through Claude Code's highest-precedence
**managed-settings** layer (`/etc/claude-code/managed-settings.json`),
run in *every* folder — including ones with no project `.claude/`:

- **`SessionStart` → `sandbox-verify.sh`** does the heavy lifting once
  per session. Its single load-bearing assertion is `IS_SANDBOX=1`, set
  only by the bwrap launcher; if unset, it warns loudly that Claude is
  running outside the shadow. When wrapped, it runs the deeper integrity
  battery (no leaked `GH_TOKEN`/`GITHUB_TOKEN`/`ANTHROPIC_API_KEY`,
  `SSH_AUTH_SOCK` or `DISPLAY`; `GIT_CONFIG_*` pinned; `/run/secrets`
  empty) and warns on any regression. A `SessionStart` hook **cannot
  block** a session — it can only inject messages and context — so it can
  only warn.
- **`UserPromptSubmit` → `sandbox-gate.sh`** is the one mechanism that
  can actually *stop* work. It is lean by design — a single string
  compare per prompt — and **fail-closed**: it blocks every prompt
  unless `IS_SANDBOX=1`, exiting non-zero so its message reaches you.

Both hooks **skip on Claude Code Web** (`CLAUDE_CODE_REMOTE=true`): that
runtime is already sandboxed by Anthropic and never sets `IS_SANDBOX`.

The escape hatch is a **root-owned flag file**,
`/etc/claude-code/allow-unwrapped`: while it exists the gate is
warn-only. The `SessionStart` warning still fires — working unwrapped is
allowed, but never silent. The operator stamps it with
`sudo touch /etc/claude-code/allow-unwrapped`, or by re-running
`./install` with `ALLOW_UNWRAPPED=1` (which also removes it again on a
later install without that variable).

It is deliberately a flag under `/etc`, **not** an environment variable.
A confined Claude can write `~/.claude/settings.json` — a host-shared,
persistent file — and Claude Code exports that file's `env` block into
later sessions. The earlier `CLAUDE_SANDBOX_ALLOW_UNWRAPPED=1` env hatch
was therefore *forgeable from inside the jail*: a compromised session
could persist it and silently neutralise the gate on a later **unwrapped**
launch (deep-review **H4**). `/etc` is read-only inside the bwrap shadow
(`--ro-bind / /`) and is not part of the host-shared config, so only
`root` on the host (or a deliberate `./install`) can create the flag —
the same "security inputs live outside the rw workspace" discipline as
{ref}`the untrusted-workspace model <adr-untrusted-workspace>` and the
managed guard itself.

```{mermaid}
flowchart TD
    A[UserPromptSubmit] --> B{CLAUDE_CODE_REMOTE=true?}
    B -- yes --> P[allow]
    B -- no --> C{IS_SANDBOX=1?}
    C -- yes --> P
    C -- no --> D{/etc/claude-code/allow-unwrapped exists?}
    D -- yes --> P
    D -- no --> X[BLOCK — exit 2]
```

## Why managed-settings and /usr/libexec, not ~/.claude

A guard that lives where the user can edit it is a guard the user can
*accidentally* edit away. Two placement choices make this one
tamper-resistant in the same `/etc`-not-the-workspace spirit as the
sandbox config:

- **Hook entries live in `/etc/claude-code/managed-settings.json`** — the
  highest-precedence settings layer. A user editing their own
  `~/.claude/settings.json` cannot remove or override the entries; only
  `root` editing `/etc` (or a deliberate `./install`) changes the guard.
- **Hook scripts live in `/usr/libexec/claude-sandbox/`** — root-owned,
  off the user's PATH, and read-only inside the sandbox (`--ro-bind /
  /`), exactly like the relocated real binary. A compromised in-session
  Claude cannot rewrite them to `exit 0`. Under `~/.claude` they would
  have been rw-bound and editable.

The installer merges the guard in idempotently (deduped by script
basename) and **preserves foreign keys** — a real enterprise admin's org
policy already in that file survives, so install merges rather than owns
the file. It deliberately does **not** set `allowManagedHooksOnly`:
doing so would suppress the owner's own user and project hooks, which the
guard has no reason to block.

User-scope `~/.claude/settings.json` keeps only the statusline
preference; the guard no longer lives anywhere you might edit it away by
accident. (An earlier install that put the guard in user scope is
migrated — those entries are pruned so the guard has a single
authoritative home in `/etc` and never double-fires.)

The result: short of `root` deleting the `/etc` policy file, you cannot
accidentally disable the guard. The native devcontainer — and any
promoted target — is safe-by-construction.

## Open follow-up: are `IS_SANDBOX` / `CLAUDE_CODE_REMOTE` themselves forgeable? (deep-review H4)

Moving the escape hatch out of the environment (above) closes the
`CLAUDE_SANDBOX_ALLOW_UNWRAPPED` forgery. But the gate's two *positive*
pass conditions are still environment variables:

```sh
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && exit 0   # skip on Claude Code Web
[ "${IS_SANDBOX:-}" = "1" ]            && exit 0   # we are inside the shadow
```

`IS_SANDBOX=1` is the gate's load-bearing "we are wrapped" signal, set
**only** by the bwrap launcher (`--setenv IS_SANDBOX 1`, a real
process-environment variable). Claude Code also merges an `env` block
from its settings files into the environment it hands to hooks and tools.
A confined Claude can write `~/.claude/settings.json` (host-shared,
persistent). **If** that user-scope `env` block can inject
`IS_SANDBOX=1` (or `CLAUDE_CODE_REMOTE=true`) into a later *unwrapped*
session's hook environment, the gate would pass even though no bwrap jail
exists — a bypass **graver** than the escape-hatch one, because it forges
the core "wrapped" proof rather than an opt-out.

Why this is *not* fixed in the same PR, and what's needed:

- **The safe pin is the managed layer.** `/etc/claude-code/managed-settings.json`
  is the highest-precedence settings tier and is root-owned (a confined
  Claude cannot write it). Pinning `CLAUDE_CODE_REMOTE` there to a known
  value would neutralise a user-scope forgery of *that* signal, since
  managed `env` outranks user `env`.
- **`IS_SANDBOX` cannot simply be pinned.** It must legitimately be `1`
  inside the real bwrap jail (set on the process env) and unset outside
  it. A managed `env.IS_SANDBOX` constant would be wrong in one of those
  two states — pinning `"1"` defeats the gate everywhere; pinning `"0"`
  could *override the bwrap-set value* and block the genuinely-wrapped
  path, bricking the sandbox. Whether managed `env` overrides a real
  process-environment variable for hook execution — and whether a
  user-scope `env` can override the bwrap process env at all — is a
  Claude-Code precedence question that must be **verified empirically on
  a live host** (we could not verify it in CI/this sandbox: it needs a
  real `claude` and root). The fail-closed fix, if user `env` *can*
  forge `IS_SANDBOX`, is to corroborate the wrapped signal with something
  the workspace cannot fake (e.g. a root-owned `/etc` marker the launcher
  re-stamps per boot, or a check that the gate script is running from the
  ro-bound `/usr/libexec` mount), not a managed `env` pin.

Until that empirical check is done, this is tracked as a follow-up to
issue #63 (H4). The escape-hatch hardening in this page is independent of
it and lands first.
