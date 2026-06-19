# Set up a devcontainer for your project

A **devcontainer** is a development environment packaged as a container and
described by one file in your repo, `.devcontainer/devcontainer.json`. Open
the project and your editor — or a CLI — builds that container and drops you
inside it, so everyone who clones the repo gets the *same* tools and
settings, with nothing installed on your host. The
[containers.dev](https://containers.dev/) overview and the [VS Code
guide](https://code.visualstudio.com/docs/devcontainers/containers) explain
the idea in full.

claude-sandbox expects one: running Claude inside a throwaway container is
the outer layer that keeps a hostile prompt away from your real environment.
[Getting started](getting-started.md) assumes you're already inside a
Debian/Ubuntu devcontainer running as `root` — this page gets you there.

> **Already have one?** If your project opens in a devcontainer today, skip
> straight back to [Getting started](getting-started.md).

## Use a rootless runtime

claude-sandbox supports **rootless** containers only. We recommend
[Podman](https://podman.io/), which is rootless by default;
[rootless Docker](https://docs.docker.com/engine/security/rootless/) works
too. Rootful Docker is **not** supported.

Rootless is what makes running as `root` safe. Inside the container you are
`root` and can install packages or change the system freely — but to your
computer you're still just you: files you create in mounted project folders
stay owned by your normal account, and that root power can't reach the rest
of your machine.

> **Using Podman with VS Code?** Point the Dev Containers extension at it by
> setting `dev.containers.dockerPath` to `podman` (see [alternative
> runtimes](https://code.visualstudio.com/remote/advancedcontainers/docker-options)).

## A minimal devcontainer

Create `.devcontainer/devcontainer.json` at the root of your project:

```json
{
  "name": "my-project",
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "remoteUser": "root",
  "runArgs": ["--device=/dev/net/tun"],
  // Mount the parent folder so your sibling projects are reachable at
  // /workspaces/<project> — handy for working across peer repos.
  "workspaceMount": "source=${localWorkspaceFolder}/..,target=/workspaces,type=bind"
}
```

That's enough to run claude-sandbox: a Debian/Ubuntu base, `remoteUser: root`
so the installer can write its system files, the
[egress jail](../how-to/network-egress-jail.md)'s required `runArg`, and a
`workspaceMount` that puts your sibling projects alongside this one under
`/workspaces`. Add a `postCreateCommand` to run claude-sandbox's `install`,
and a bind mount to [persist your Claude login across
rebuilds](../how-to/persist-login-and-memory.md); every other key is in the
[`devcontainer.json`
reference](https://containers.dev/implementors/json_reference/).

## You don't need VS Code

Devcontainers are an [open specification](https://containers.dev/), not a
VS Code feature. VS Code and GitHub Codespaces are the easiest on-ramps, but
the [devcontainer CLI](https://github.com/devcontainers/cli) builds and
enters one straight from a terminal:

```bash
npm install -g @devcontainers/cli
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash
```

You're now inside the container and can run `./install` and `claude` as
[Getting started](getting-started.md) describes.

## Next steps

- [Getting started](getting-started.md) — install the sandbox in your new
  devcontainer and prove it is intact.
