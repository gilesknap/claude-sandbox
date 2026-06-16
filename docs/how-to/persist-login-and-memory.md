# Persist your login and memory across rebuilds

By default a container rebuild wipes `~/.claude` and `~/.claude.json`, so you
lose your Claude login (OAuth token), chat history, and any skills or
settings you've added — and have to log in again.

The fix is one bind mount. Point a host directory at `/user-terminal-config`
in your `devcontainer.json`:

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

`python-copier-template` devcontainers already set this mount up for you, so
there's nothing to do there.

If you mount at a path other than `/user-terminal-config`, set
`CLAUDE_SHARED_CONFIG` to that target before `./install` runs so the
installer finds it.
