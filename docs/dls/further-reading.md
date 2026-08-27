# Further reading for DLS

Detail deliberately kept off [Claude Code at DLS](claude-at-dls.md) to
keep that page tight.

## Claude in every devcontainer, automatically

Devcontainers that mount `/user-terminal-config` and source its `bashrc`
(all `python-copier-template` devcontainers do) have a run-once section
in `/user-terminal-config/bashrc` that executes on a container's first
shell. Add the install one-liner there:

```bash
cd /tmp && rm -rf claude-sandbox && git clone https://github.com/DiamondLightSource/claude-sandbox && claude-sandbox/install
```

Every devcontainer you open then installs the sandbox on first use,
with no per-project setup beyond the three `devcontainer.json` items.

## What the three devcontainer.json items are for

- **`"runArgs": ["--device=/dev/net/tun"]`**: the one hard container
  requirement of the
  [network egress jail](../how-to/network-egress-jail.md). The jail is
  fail-closed: without the device, `claude` refuses to launch rather
  than run with lateral movement open.
- **The `/user-terminal-config` mount**: the installer symlinks
  `~/.claude` and `~/.claude.json` into it, so your Claude login,
  memory, and settings live on the host, survive rebuilds, and are
  shared by every devcontainer that mounts the same directory. See
  [Persist your login and memory](../how-to/persist-login-and-memory.md).
- **The `initializeCommand`**: creates the host directory as *you*
  before the container starts; otherwise the container engine creates
  it root-owned and the mount fights your host UID.

## Forge access and the Diamond network

- `claude-sandbox glab-auth` defaults to `gitlab.diamond.ac.uk`; the
  shipped configuration already punches Diamond's GitLab through the
  egress jail's internal-network blackhole. Any other internal host a
  session must reach needs an `allow-ip` entry; see
  [Configure the network egress jail](../how-to/network-egress-jail.md).
- Tokens are container-scoped on purpose: re-pasting a short-lived PAT
  after a rebuild is the cost of keeping a leaked token's blast radius
  small. See [Authenticate with forges](../how-to/authenticate-with-forges.md).

## Other supported routes

The main page prescribes one route to keep the instructions simple.
Also supported:

- **The prebuilt container image**: sandboxed Claude with no
  devcontainer at all, via rootless Podman and a small launcher. See
  [Use the container image](../how-to/use-the-container-image.md).
- **Team rollout at a pinned tag**: a project's `postCreate` clones
  claude-sandbox at a pinned release and installs it, so every teammate
  gets an identical, reviewable sandbox with no manual step. See
  [Sandbox a team devcontainer](../how-to/sandbox-a-team-devcontainer.md).

## Without VS Code: the devcontainer CLI

VS Code is only one way into a devcontainer. If you work in a terminal
editor, or over plain SSH to a DLS workstation, the
[devcontainer CLI](https://github.com/devcontainers/cli) starts the same
container from the same `devcontainer.json` — including the
`runArgs`, `mounts`, and `initializeCommand` from
[step 3](claude-at-dls.md#install-and-run), so the egress jail's tun
device and your persisted Claude login work exactly as they do under VS
Code. epics-containers documents the general workflow in
[Using the devcontainer CLI](https://epics-containers.github.io/main/how-to/own_tools.html#using-the-devcontainer-cli);
the DLS-specific parts are:

```bash
module load node                       # only if node/npm are not already on PATH
npm config set prefix ~/.local         # keep the CLI out of the repo, off /usr
npm install -g @devcontainers/cli
export DOCKER_PATH=$(which podman)     # DLS workstations run rootless podman
```

Add `~/.local/bin` to your `PATH` if it is not there already. Then, from
the project directory on the *host* (not inside any container):

```bash
devcontainer up --workspace-folder .            # build and start
devcontainer exec --workspace-folder . bash     # a shell inside it
```

In that shell, continue from
[step 4](claude-at-dls.md#install-and-run): run the installer, then
`claude`. Note the ordering — `devcontainer up` runs `initializeCommand`
on the host, so `~/.config/terminal-config` is created as *you* before
the mount happens, just as with "Reopen in Container".

Two DLS gotchas:

- **UID remapping.** Rootless podman can fail the container's user
  remapping step; add `"updateRemoteUserUid": false` to
  `devcontainer.json` if you hit it.
- **No `devcontainer down`.** Stop and remove with podman directly
  (`podman ps`, then `podman stop <name>` / `podman rm -f <name>`), and
  rebuild after a Dockerfile change with
  `devcontainer up --workspace-folder . --remove-existing-container`.

Wanting a terminal-only route because you have no devcontainer at all is
a different problem — use
[the container image](../how-to/use-the-container-image.md) instead.

