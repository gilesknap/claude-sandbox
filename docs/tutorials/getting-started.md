# Getting started

This tutorial gets you to a working, sandboxed Claude Code — and proves the
sandbox is intact before you trust it. You'll be working inside a
Debian/Ubuntu [devcontainer](set-up-a-devcontainer.md) running as `root`
(the typical rootless-Podman pattern; rootless Docker works too). New to
devcontainers? [Set one up first](set-up-a-devcontainer.md).

There are two ways in. Pick whichever fits how you already work.

## The quick way: use claude-sandbox's own devcontainer

Open **this repo** (`claude-sandbox`) in its devcontainer. That's it — the
sandbox installs itself:

- `postCreate` runs the installer for you, so the shadow `claude` and the
  global integrity guard are in place the moment the container comes up.
- The parent directory is mounted at `/workspaces`, so all your **peer
  projects sit right there** at `/workspaces/<project>`.
- Your Claude login and memory persist across rebuilds automatically.
- Claude's network egress is jailed by default — RFC1918 internal hosts and
  lab devices are blackholed so a compromised session can't pivot to them,
  while the internet, DNS, and any `allow-ip` devices stay reachable. This
  repo's devcontainer already ships the one required runArg
  (`--device=/dev/net/tun`); see [Configure the network egress
  jail](../how-to/network-egress-jail.md) to add `allow-ip` devices or turn
  it off.

So to work on any project, just:

```bash
cd /workspaces/<your-project>
claude
```

`claude` is sandboxed wherever you launch it. By default the writable root
is the directory you launch from, so that project is editable and the
others stay read-only — usually exactly what you want. (To widen it, see
[Configure the workspace scope](../how-to/configure-workspace-scope.md).)

This is the simplest path, especially if your own projects don't have
devcontainers. Skip to [Confirm the sandbox](#confirm-the-sandbox) to prove
it's working.

## The other way: add the sandbox beside your own project

Already working inside your own project's devcontainer? Add claude-sandbox
next to it.

### 1. Clone beside your project

Clone it as a **sibling** of your project — not inside it — so it lives on
the host, survives container rebuilds, and one clone sandboxes every project
beside it:

```bash
cd ..        # the host-mounted parent of your project
git clone https://github.com/gilesknap/claude-sandbox.git
cd claude-sandbox
```

(This assumes your project's parent directory is mounted, as it is for
`python-copier-template` and most DLS devcontainers.)

### 2. Run the installer

```bash
./install
```

This relocates the real Claude binary off your `PATH` and drops a shadow
`claude` in its place that wraps every invocation in `bwrap`. It also
installs the global integrity guard and a curated gitconfig. Curious where
everything lands? See [What's installed](../reference/whats-installed.md).

If your host can't run unprivileged user namespaces, the installer
**refuses** with a specific, actionable diagnostic rather than installing a
non-functional sandbox. Fix the reported problem and re-run.

> **Note: the egress jail needs `/dev/net/tun`.** By default Claude's
> network egress is jailed — a per-process netns that blackholes internal
> RFC1918 hosts and lab devices so a compromised session can't pivot to them
> (see the [threat
> model](../explanations/threat-model.md#the-egress-jail-and-the-native-sandbox)).
> The jail is *fail-closed*: if the container has no `/dev/net/tun` device,
> `claude` **refuses to launch** and tells you so. `install` apt-installs
> `passt` (which provides `pasta`), but it **cannot** add the runArg for you
> — that's a `devcontainer.json` edit. Add `"--device=/dev/net/tun"` to your
> `devcontainer.json` `runArgs` and rebuild (this repo's own devcontainer
> already does). If you don't need lateral isolation, set
> `CLAUDE_SANDBOX_EGRESS_JAIL=0` to turn the jail off instead. See [Configure
> the network egress jail](../how-to/network-egress-jail.md).

To restore the sandbox automatically on every rebuild, wire `bash
<clone>/install` into your devcontainer's `postCreate.sh`.

### 3. Run Claude

```bash
claude
```

Use Claude exactly as you normally would — the shadow on your `$PATH` wraps
plain `claude` in the sandbox, nothing else to remember.

## Confirm the sandbox

From inside the Claude session, run:

```
/verify-sandbox
```

This runs the **18-check PASS/FAIL battery**, and — when the battery
passes — follows it with **10 adversarial breakout probes** against the
live process. It **exits non-zero on any FAIL**, so the same command
doubles as a CI assertion.

A clean run means your host credentials, IDE bridges, and shell environment
are isolated from anything Claude reads or runs. If you see a FAIL, stop and
resolve it before trusting the session.

## Re-run freely after a rebuild

The installer is idempotent. After a devcontainer rebuild, just run it again
(or let `postCreate` do it):

```bash
./install
```

The shadow is re-established **without re-downloading Claude**.

Your statusline script is seeded once and then left alone, so edits you make
to it survive re-runs. If you'd rather a re-run pull the clone's current
statusline, run `STATUS=1 ./install`.

---

> **Note:** `just promote` (copying the sandbox's commands into a workspace
> so they're available in place) still exists, but the sibling clone above
> covers the common case and is the recommended workflow. See [Promote a
> workspace](../how-to/promote-to-a-workspace.md) only if you need it.

## Next steps

- [Persist your login and memory across rebuilds](../how-to/persist-login-and-memory.md)
  — add a terminal-config mount if your devcontainer doesn't already have one.
- [Configure the network egress jail](../how-to/network-egress-jail.md) —
  the jail is on by default; add `allow-ip` lab devices, satisfy the
  `--device=/dev/net/tun` requirement, or turn it off. It provides
  *lateral* (RFC1918) isolation and composes with Claude Code's native
  `allowedDomains` *internet-domain* isolation as complementary layers — run
  both.
- [How-to guides](../how-to.md) — focused recipes for authenticating with
  forges, widening writable paths, and more.
- [Architecture and threat model](../explanations.md) — why the sandbox is
  built the way it is, and what it does and doesn't protect.
- [Reference](../reference.md) — the configuration keys, the integrity
  battery, and the moving parts, looked up dryly.
