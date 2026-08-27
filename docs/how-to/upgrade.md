# Upgrade claude-sandbox

```bash
claude-sandbox update
```

This clones the latest **release** into a fresh temporary directory,
checks out its tag, runs the installer, and records the version — check
what you have with:

```bash
claude-sandbox version
```

The installer is idempotent; the shadow is re-established without
re-downloading Claude. No persistent clone is needed — the temporary one
is removed after the install.

(Inside the published container image, update by pulling a newer image
and recreating the container instead — see
[Use the container image](use-the-container-image.md).)

## Why upgrades are deliberate

Claude Code's in-container auto-updater is **disabled**
(`env.DISABLE_AUTOUPDATER=1` + `autoUpdates:false`). The updater otherwise
re-creates `~/.local/bin/claude` on a version bump, which — depending on
your `PATH` order — can launch the real binary *unwrapped*, with no bwrap
and no git steering. This is self-entrenching and silent.

With the updater off, updates happen only when *you* run
`claude-sandbox update` (or re-run the installer from a clone). Updating:

- re-relocates the current Claude binary to
  `/usr/libexec/claude-sandbox/claude` (off the user's PATH), and
- re-asserts the shadow at `/usr/local/bin/claude`.

For why this root-cause removal matters and how the global guard fails loud
if an unwrapped binary ever appears anyway, see the
[integrity guard explanation](../explanations/integrity-guard.md).
