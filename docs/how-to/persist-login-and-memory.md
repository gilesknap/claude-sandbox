# Persist your login and memory across rebuilds

> **Using `python-copier-template`?** This is already set up for you — its
> devcontainer mounts the terminal-config directory and creates it on the
> host first. There's nothing to do; skip this page.

By default a container rebuild wipes `~/.claude` and `~/.claude.json`, so you
lose your Claude login (OAuth token), chat history, and any skills or
settings you've added — and have to log in again.

The fix is a host directory bind-mounted into the container, in two parts.

## 1. Create the host directory before the container starts

Add an `initializeCommand` so the host-side directory exists before the
mount is wired. This runs on the **host**, as you, before the container is
created:

```json
"initializeCommand": "mkdir -p \"$HOME/.config/terminal-config\""
```

Without this, Docker/Podman creates the missing bind source itself as a
**root-owned** directory, which then fights your host UID — so create it as
yourself first.

## 2. Mount it into the container

Point that host directory at `/user-terminal-config`:

```json
"mounts": [
  "source=${localEnv:HOME}/.config/terminal-config,target=/user-terminal-config,type=bind"
]
```

Rebuild the container and re-run `./install` (or let `postCreate` run it).
The installer symlinks `~/.claude` and `~/.claude.json` into the mounted
directory, so your login and memory now live on the host: they survive
rebuilds, and they're shared with every other devcontainer that mounts the
same directory.

If you mount at a path other than `/user-terminal-config`, set
`CLAUDE_SHARED_CONFIG` to that target before `./install` runs so the
installer finds it.
