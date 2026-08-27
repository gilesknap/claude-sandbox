# Make extra paths writable

By default the sandbox makes only `$PWD` writable. Sibling projects under
`/workspaces/` are read-only. This recipe covers the two ways to widen
that scope.

## Restore the broad `/workspaces` bind

To make every sibling devcontainer project writable again, set
`CLAUDE_SANDBOX_WORKSPACE_ROOT` in your devcontainer's `remoteEnv`:

```json
// .devcontainer/devcontainer.json → remoteEnv
"CLAUDE_SANDBOX_WORKSPACE_ROOT": "/workspaces"
```

Restart (or rebuild) the devcontainer for the change to take effect.

## Add specific writable paths

For extra writable paths without widening to all of `/workspaces`, add
`allow-write` lines to the sandbox config — edit `/etc/claude-sandbox.conf`
in the container (you are root in a devcontainer):

```ini
# /etc/claude-sandbox.conf
allow-write = /cache
allow-write = /workspaces/sibling-project
```

One absolute path per line. Blank lines and `#` comments are ignored;
non-existent paths are skipped.

The same conf also carries the network-jail keys `egress-jail` and
`allow-ip` (the on-by-default lateral-movement isolation). Those are
covered in [Configure the network egress jail](network-egress-jail.md);
for the full key reference see
[Configuration](../reference/configuration.md).

A path may be a directory, a file, or a unix socket.

## Reach a container-engine socket

:::{warning}
**A container-engine socket is a sandbox escape.** Whoever holds the
engine socket can start a container that bind-mounts any path the
engine's account can read — your `$HOME`, your ssh keys, the sandbox
conf itself — and run arbitrary code there, outside every jail this
project builds. Binding the socket in hands the agent exactly that
power: the sandbox can restrict which paths the *socket file* is
reachable at, but it cannot constrain what the engine on the far side
will do when asked.

**Do not expose your host's podman/docker socket** — including one
already mounted into your devcontainer. If the agent genuinely needs a
container engine, give it a dedicated, disposable one that holds
nothing you care about (a rootless engine under a throwaway account, or
an engine inside the devcontainer itself).

The same reasoning applies to **any** socket, not just container
engines: a socket is an API, and binding it into the sandbox grants the
agent everything that API can do with *your* privileges. Before
exposing one, think through what is listening on the other end and what
you are giving the agent.
:::

The shape that stays inside the warning above is an engine that exists
*only for this devcontainer*: a rootless engine started inside the
container, under the container user, holding no images, volumes or
mounts you care about — e.g. `podman system service --time=0 &`. Its
socket lands under the container's own `$XDG_RUNTIME_DIR` — typically
`/run/user/<uid>/podman/podman.sock` or `/run/user/<uid>/docker.sock`.
The sandbox masks `/run/user` with a tmpfs, because that directory is
also where ssh-agent, gpg-agent, dbus and keyring sockets live.

`allow-write` re-exposes a single path *through* that mask, so name the
socket itself rather than lifting the mask off the whole directory:

```ini
# The dedicated in-container engine socket, and nothing else under /run/user.
allow-write = /run/user/1000/podman/podman.sock
```

Use the uid of the account running the engine (`id -u`). Since the conf
describes one container, a hardcoded uid is fine.

What must **not** go on that line is the path where your devcontainer
mounts the *host's* engine socket — a common `devcontainer.json` pattern
mounts the host's `podman.sock` or `/var/run/docker.sock` into the
container so builds can reuse the host engine. That mount is exactly
what the warning above is about: it is your host's engine, and no
`allow-write` scoping makes it safe to hand to the agent.

Making the socket reachable is only half the job: the sandbox scrubs the
environment, so `DOCKER_HOST` does not survive into the session —
[forward it with pass-env](pass-environment-variables.md) so the client
finds the socket.

Prefer the socket path over the enclosing directory: `allow-write =
/run/user/1000` would work, but it unmasks the agent and keyring sockets
next to it, handing a compromised session your ssh credentials.

The engine socket is a unix socket, not a network connection, so the
[egress jail](network-egress-jail.md) does not stand in its way.

## Applying the change

The shadow reads `/etc/claude-sandbox.conf` at every launch, so an edit
takes effect on the next `claude` — no re-install needed.

Edits are **per-devcontainer and not persisted**: a container rebuild
recreates `/etc` from the image, and a re-install or `claude-sandbox
update` re-stamps the conf with the shipped defaults — re-apply your
lines afterwards. (Teams that want a persistent, reviewable conf bake it
in at install time instead — see
[Sandbox a team devcontainer](sandbox-a-team-devcontainer.md).)

## Why the conf lives in `/etc`, not the workspace

The config is read from `/etc/claude-sandbox.conf` rather than from the
rw-bound workspace so that a compromised in-session Claude cannot rewrite
it to widen the next launch's binds — `/etc` is not writable from inside
the sandbox, so editing it requires an unsandboxed root shell like your
container terminal. See the
[threat model](../explanations/threat-model.md) for why the
workspace itself is not a trusted location.
