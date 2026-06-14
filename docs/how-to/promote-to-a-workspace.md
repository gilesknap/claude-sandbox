# Promote a host workspace

`just promote` makes a target workspace a self-sufficient claude-sandbox
host: a teammate who clones the target only needs the devcontainer to come
up, and the installer runs from `postCreate.sh` with the curated `.claude/`
already in tree.

```bash
just promote                       # promote into $PWD
just promote /workspaces/fastcs    # promote into the named target
```

## What lands in the target

1. **Curated `.claude/`** — commands and skills. The integrity guard is
   **not** seeded per-repo; it's global (wired into `~/.claude` by
   `install.sh`, which the target's `postCreate` runs), so promote does not
   touch the target's project `settings.json`, hooks, or statusline.
2. **Install machinery** —
   `.devcontainer/claude-sandbox/{install.sh, claude-shadow, promote.sh}`,
   so postCreate can run `install.sh` directly. The root `install` shim is
   *not* copied.
3. **`.devcontainer/postCreate.sh`** running
   `bash .devcontainer/claude-sandbox/install.sh` — created if absent,
   idempotently appended otherwise.

## Wire `postCreateCommand` yourself

After it finishes, promote prints a one-line `"postCreateCommand"` snippet
to paste into the target's `.devcontainer/devcontainer.json`:

```json
// .devcontainer/devcontainer.json
"postCreateCommand": "bash .devcontainer/postCreate.sh"
```

promote deliberately does **not** auto-edit `devcontainer.json`: it's JSONC
in the wild, structured editing while preserving comments is more code than
this repo wants, and you're the one who knows whether you've already wired
it or need to combine it with an existing `postCreateCommand`. This is a
one-time edit; subsequent `just promote` runs are byte-stable.

## Idempotency and safety

- `just promote` is idempotent — re-running from this clone re-syncs the
  copied files byte-equal.
- It refuses self-targeting (`TARGET == clone`).
- It does **not** touch `~/.claude`. The global integrity guard lives in
  `/etc/claude-code/managed-settings.json` + `/usr/libexec/claude-sandbox/`,
  written by `install.sh` (which the target's `postCreate` runs), not by
  promote.

For the three-layer model behind what promote seeds versus what the
installer establishes globally, see the
[architecture explanation](../explanations/architecture.md).
