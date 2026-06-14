# Getting started

This tutorial walks you from an empty Debian/Ubuntu devcontainer to a
working, sandboxed Claude Code — and proves the sandbox is intact before
you trust it. By the end you'll have cloned the repo, run the installer,
launched `claude`, and watched the integrity battery pass.

You'll be working inside a Debian/Ubuntu devcontainer running as `root`
(the typical rootless-Podman pattern; rootless Docker works too).

## 1. Clone the repo

Inside your devcontainer:

```bash
git clone https://github.com/gilesknap/claude-sandbox.git
cd claude-sandbox
```

## 2. Run the installer

```bash
./install
```

This relocates the real Claude binary off your `PATH` and drops a shadow
`claude` in its place that wraps every invocation in `bwrap`. It also
installs the global integrity guard and a curated gitconfig.

If your host can't run unprivileged user namespaces, the installer
**refuses** with a specific, actionable diagnostic rather than installing
a non-functional sandbox. That's by design — fix the reported problem and
re-run.

## 3. Run Claude

```bash
claude
```

Use Claude exactly as you normally would. Because the shadow now sits on
your `$PATH`, plain `claude` is automatically wrapped in the sandbox —
nothing else to remember.

```{include} ../_snippets/clone-note.md
```

## 4. Confirm the sandbox with `/verify-sandbox`

From inside the Claude session, run:

```
/verify-sandbox
```

This runs the **18-check PASS/FAIL battery**, and — when the battery
passes — follows it with **10 adversarial breakout probes** against the
live process. It **exits non-zero on any FAIL**, so the same command
doubles as a CI assertion.

A clean run means your host credentials, IDE bridges, and shell
environment are isolated from anything Claude reads or runs. If you see a
FAIL, stop and resolve it before trusting the session.

## 5. Re-run freely after a rebuild

The installer is idempotent. After a devcontainer rebuild, just run it
again:

```bash
./install
```

The shadow is re-established **without re-downloading Claude**. To
automate this, wire `bash <clone>/install` into your devcontainer's
`postCreate.sh` so the sandbox is restored on every rebuild.

## Optional: terminal-config clone location

If your devcontainer bind-mounts `~/.config/terminal-config` at
`/user-terminal-config` (the `python-copier-template` convention), clone
there instead of inside the workspace:

```bash
cd /user-terminal-config
git clone https://github.com/gilesknap/claude-sandbox.git
cd claude-sandbox
./install
```

The clone then lives on the host under `~/.config/terminal-config`, so it
survives rebuilds and is reusable from every devcontainer that mounts the
same terminal-config dir — one clone, every project sandboxed.

## Next steps

- [How-to guides](../how-to.md) — focused recipes for authenticating with
  forges, widening writable paths, and promoting the sandbox into another
  workspace.
- [Architecture and threat model](../explanations.md) — why the sandbox is
  built the way it is, and what it does and doesn't protect.
- [Reference](../reference.md) — the configuration keys, the integrity
  battery, and the moving parts, looked up dryly.
