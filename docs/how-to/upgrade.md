# Upgrade claude-sandbox

```bash
git pull --ff-only && bash install
```

The installer is idempotent; the shadow is re-established without
re-downloading Claude.

## Why upgrades are deliberate

Claude Code's in-container auto-updater is **disabled**
(`env.DISABLE_AUTOUPDATER=1` + `autoUpdates:false`). The updater otherwise
re-creates `~/.local/bin/claude` on a version bump, which — depending on
your `PATH` order — can launch the real binary *unwrapped*, with no bwrap
and no git steering. This is self-entrenching and silent.

With the updater off, updates happen only when *you* re-run the installer.
Re-running `bash install`:

- re-relocates the current Claude binary to
  `/usr/libexec/claude-sandbox/claude` (off the user's PATH), and
- re-asserts the shadow at `/usr/local/bin/claude`.

For why this root-cause removal matters and how the global guard fails loud
if an unwrapped binary ever appears anyway, see the
[integrity guard explanation](../explanations/integrity-guard.md).
