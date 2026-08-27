# Getting started

This tutorial gets you to a working, sandboxed Claude Code. You'll be
working inside a
Debian/Ubuntu [devcontainer](set-up-a-devcontainer.md) running as `root`
(the typical rootless-Podman pattern; rootless Docker likely works but is
untested with the egress jail).

There are two ways in. **New to devcontainers? Take the quick way** — this
repo ships its own devcontainer, so there is nothing to build or configure
yourself. The other way is for when you already work inside your own
project's devcontainer (and if your project doesn't have one yet,
[set one up first](set-up-a-devcontainer.md)).

## The quick way: use claude-sandbox's own devcontainer

Clone **this repo** and open it in VS Code:

```bash
git clone https://github.com/DiamondLightSource/claude-sandbox
code claude-sandbox
```

When VS Code offers **"Reopen in Container"**, accept it (or press `F1` and
run **"Dev Containers: Reopen in Container"**). That's it — the sandbox
installs itself:

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
devcontainers.

## The other way: install into your own devcontainer

Already working inside your own project's devcontainer? Install
claude-sandbox into it.

### 1. Clone and install

In a terminal inside the container:

```bash
cd /tmp && rm -rf claude-sandbox && git clone https://github.com/DiamondLightSource/claude-sandbox && claude-sandbox/install
```

This installs the **newest release**, not the tip of `main`: the clone
lands on the default branch, and `install` then checks out the newest
release tag before installing it — the same revision `claude-sandbox
update` would give you. It prints which one it picked. (To install a
specific release instead: `claude-sandbox/install --release 3.0.0`.)

The clone is **disposable** — nothing depends on it after install (the
`claude-sandbox` helper CLI lands on your PATH, and
`claude-sandbox update` fetches its own fresh clone when you upgrade), so
`/tmp` is exactly the right place: it evaporates with the container.

The installer relocates the real Claude binary off your `PATH` and drops a shadow
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
> already does). See [Configure the network egress
> jail](../how-to/network-egress-jail.md).

To restore the sandbox automatically on every rebuild, wire the same
clone-and-install one-liner into your devcontainer's `postCreate.sh`
(pin a tag there if you want a reviewable rollout — see [Sandbox a team
devcontainer](../how-to/sandbox-a-team-devcontainer.md)).

### 2. Run Claude

```bash
claude
```

Use Claude exactly as you normally would — the shadow on your `$PATH` wraps
plain `claude` in the sandbox, nothing else to remember.

## Re-run freely after a rebuild

The installer is idempotent. After a devcontainer rebuild, just run the
clone-and-install one-liner again (or let `postCreate` do it). Once
installed, `claude-sandbox update` upgrades you to the latest release and
`claude-sandbox version` reports what you have.

The shadow is re-established **without re-downloading Claude**.

Your statusline script is seeded once and then left alone, so edits you make
to it survive re-runs. If you'd rather a re-run pull the clone's current
statusline, run `STATUS=1 <clone>/install --here` (`--here` because the
clone is now checked out at the release it installed, and re-running
without it would ask to move to a newer one).

---

> **Note:** rolling the sandbox out to a whole team? Wire the clone-and-install
> into your project's `postCreate` at a pinned tag — see [Sandbox a team
> devcontainer](../how-to/sandbox-a-team-devcontainer.md).

## Next steps

- [Verify the sandbox](../how-to/verify-the-sandbox.md) — the sandbox ships
  with an integrity battery and adversarial breakout probes; run them any
  time you want proof, or wire them into CI.
- [Persist your login and memory across rebuilds](../how-to/persist-login-and-memory.md)
  — add a terminal-config mount if your devcontainer doesn't already have one.
- [Configure the network egress jail](../how-to/network-egress-jail.md) —
  the jail is on by default; add `allow-ip` lab devices or satisfy the
  `--device=/dev/net/tun` requirement. It provides
  *lateral* (RFC1918) isolation and composes with Claude Code's native
  `allowedDomains` *internet-domain* isolation as complementary layers — run
  both.
- [How-to guides](../how-to.md) — focused recipes for authenticating with
  forges, widening writable paths, and more.
- [Architecture and threat model](../explanations.md) — why the sandbox is
  built the way it is, and what it does and doesn't protect.
- [Reference](../reference.md) — the configuration keys, the integrity
  battery, and the moving parts, looked up dryly.
