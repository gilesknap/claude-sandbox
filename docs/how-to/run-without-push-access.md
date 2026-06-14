# Run without push access

Run a session where Claude cannot push code at all — no `gh` / `glab`
token is exposed to the sandbox.

## Set the flag

Add `CLAUDE_SANDBOX_NO_FORGE=1` to your devcontainer's `remoteEnv`:

```json
// .devcontainer/devcontainer.json → remoteEnv
"CLAUDE_SANDBOX_NO_FORGE": "1"
```

A commented-out example is included in this repo's `devcontainer.json`.

## Apply it

Restart (or rebuild) the devcontainer for the change to take effect.

## Result

- The `gh` / `glab` token binds are skipped entirely — neither token
  store is mounted into the sandbox.
- The credential helpers are removed from the generated gitconfig, so
  `git push` fails inside the sandbox — intentionally, by design.

## See also

- [Authenticate with forges](authenticate-with-forges.md) — the inverse:
  set up push access when you do need it.
