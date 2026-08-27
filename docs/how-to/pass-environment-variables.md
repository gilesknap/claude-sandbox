# Pass environment variables in

The sandbox scrubs the environment (`--clearenv`) and re-exports only what
Claude itself needs — `TERM`, `LANG`, `VIRTUAL_ENV`, the `UV_*` vars and a
few others. Nothing else survives, including variables the surrounding
devcontainer set via `containerEnv`, `runArgs -e=…` or `remoteEnv`.

That is deliberate: the sandbox builds its environment rather than
inheriting one, so a variable reaches the session only if something says
it should. This recipe is how you say so.

:::{warning}
**Every variable you forward is disclosed to the agent** — and to every
tool, test and script the session runs, and potentially to the model
provider in context. Before adding a name to `pass-env`, check what
your shell actually holds under it: tokens, API keys, cloud credentials
and connection strings with embedded passwords are all one `env` away
once forwarded. Forward the minimum, prefer pointer variables
(`DOCKER_HOST`, a path, a hostname) over secret-bearing ones, and never
forward a variable whose value you would not paste into the chat.

If a variable points at a unix socket, forwarding the name is the small
half of the decision — see the warning in
[Make extra paths writable](configure-workspace-scope.md) before
binding the socket itself in.
:::

## Symptoms

The environment is empty rather than wrong, so the failure usually shows
up as something further downstream:

```console
$ env | grep DOCKER_HOST      # inside the sandbox
                              # (nothing)
```

A test suite that reads its configuration from the environment tends to
fail in a way that doesn't mention the environment at all — a fixture that
skips its `yield`, a client that falls back to a default socket path. If a
command works in your devcontainer terminal but not under `claude`, check
the environment first.

## Forward a variable

Name it with `pass-env` in the sandbox config — edit
`/etc/claude-sandbox.conf` in the container (you are root):

```ini
# /etc/claude-sandbox.conf
pass-env = DOCKER_HOST
pass-env = MY_SERVICES_PATH, MY_FIXTURE_DIR
```

Comma- or space-separate the names, and/or repeat the key. The next
`claude` launch picks it up. Edits are per-devcontainer and not
persisted — a rebuild, re-install, or `claude-sandbox update` restores
the shipped defaults.

These are **names, not assignments**. The value is read from the
environment `claude` is launched with, so `pass-env` forwards what your
shell already has and cannot invent a value of its own. A variable that is
unset at launch is skipped.

## Forward one for a single session

`CLAUDE_SANDBOX_PASS_ENV` does the same thing without touching the conf,
which is handy for a one-off:

```console
$ CLAUDE_SANDBOX_PASS_ENV=DOCKER_HOST claude
```

## What you cannot forward

The variables the sandbox sets itself — `PATH`, `HOME`, `USER`,
`IS_SANDBOX`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM` — and the
loader/shell startup hooks (`LD_*`, `BASH_ENV`, `ENV`, `SHELLOPTS`,
`BASHOPTS`, `IFS`) are ignored. The sandbox's own value wins.

These aren't arbitrary: forwarding `PATH` would undo the shadow's PATH
discipline that makes plain `claude` resolve to the sandbox, `IS_SANDBOX`
would trip the recursion guard into skipping the jail, and `LD_PRELOAD`
runs code of someone else's choosing in every process the session spawns.
See the [configuration reference](../reference/configuration.md) for the
full list.

## Why not just inherit the container's environment?

Because the environment is an input to the sandbox, not a detail of it.
Inheriting wholesale would carry in whatever the surrounding container
happens to hold — cloud credentials, tokens injected by a CI runner, a
`LD_PRELOAD` set three layers up — and the sandbox would have no say in it.
The allowlist keeps the set of things that cross the boundary small enough
to read, which is the same principle as the bind-mount allowlist in the
[threat model](../explanations/threat-model.md).

The cost is this page: variables your project needs have to be named once.
