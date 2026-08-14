# Claude Code at DLS

This page sets out the Diamond Light Source policy for running Claude
Code: **why** it must not run directly on a workstation, **what** we run
instead, and **how** to set that up. The setup instructions deliberately
prescribe a single recommended route; other supported
routes are collected in [Further reading for DLS](further-reading.md).

## The risks, and what the sandbox mitigates

Claude Code is an *agentic* tool: it runs shell commands, edits files,
and fetches from the network on your behalf. Run directly on a
workstation, two things compound:

- **Everything you can read, it can read**: SSH keys, tokens,
  browser/IDE state, kerberos caches, and every network the workstation
  reaches, including beamline and office networks.
- **It can be steered by content it merely *reads*.** A hostile file,
  web page, or dependency README can inject instructions (prompt
  injection). Combined with the above, that is a path from "opened an
  issue with Claude" to credential theft, data exfiltration, or lateral
  movement to internal hosts.

[claude-sandbox](https://github.com/DiamondLightSource/claude-sandbox)
mitigates this by wrapping every `claude` launch in a
[bubblewrap](https://github.com/containers/bubblewrap) jail, inside a
devcontainer:

- **Filesystem**: only the project workspace is writable; the rest of
  the container is read-only and host credentials are masked or empty.
- **Network**: a fail-closed egress jail blackholes internal (RFC1918)
  networks, so a compromised session cannot pivot to facility servers or
  network devices; the internet and explicitly allowed devices stay
  reachable.
- **Integrity**: a guard delivered through Claude Code's
  managed-settings layer fails loud and closed if `claude` is ever
  launched unwrapped.

The full analysis is in the
[threat model](../explanations/threat-model.md); the
[verification checks](../reference/verification-checks.md) are runnable
on any install via `claude-sandbox verify`. As evidence of the checks in
practice, see an
[example expanded audit run](https://gist.github.com/gilesknap/a294d4ee803ec96c6f89196b4f011f0e):
210 adversarial probes against a live sandbox.

## How we use Claude at DLS

1. **Never run directly on the host.** DLS-managed configuration blocks
   Claude Code launched on a workstation outside the sandbox (a
   managed-settings gate that user configuration cannot override) and
   points the user at this page.
2. **Always run inside a devcontainer, sandboxed.** All Claude Code use happens
   in a project devcontainer with claude-sandbox installed; the setup is
   below.

## Install and run

You do not need prior VS Code or devcontainer knowledge; each step links
to the detail. If you would rather not use VS Code, the same route works
from a terminal with the devcontainer CLI:
[Without VS Code: the devcontainer CLI](further-reading.md#without-vs-code-the-devcontainer-cli).

### 1. Open your project in VS Code

```bash
module load vscode
code /path/to/my-project
```

### 2. Open it in its devcontainer

A [devcontainer](https://code.visualstudio.com/docs/devcontainers/containers)
is a project-defined container VS Code develops inside; DLS projects
generated from `python-copier-template` already have one. VS Code will
offer **"Reopen in Container"** when the project has a
`.devcontainer/devcontainer.json`. Accept it.

No devcontainer yet? Create a minimal one first:
[Set up a devcontainer for your project](../tutorials/set-up-a-devcontainer.md).

### 3. Add three items to devcontainer.json

In your project's `.devcontainer/devcontainer.json`:

```json
"runArgs": ["--device=/dev/net/tun"],
"mounts": [
  "source=${localEnv:HOME}/.config/terminal-config,target=/user-terminal-config,type=bind"
],
"initializeCommand": "mkdir -p \"$HOME/.config/terminal-config\""
```

(If a key already exists, merge the entry into it.) The tun device
powers the network egress jail; the mount makes your Claude login and
memory survive rebuilds and follow you across devcontainers; the
`initializeCommand` creates the host directory the mount needs. Details:
[Further reading for DLS](further-reading.md).

Then rebuild: `F1` → **"Dev Containers: Rebuild Container"**.

### 4. Install claude-sandbox

In a terminal inside the container (`` Ctrl+` `` in VS Code), paste:

```bash
cd /tmp && rm -rf claude-sandbox && git clone https://github.com/DiamondLightSource/claude-sandbox && claude-sandbox/install
```

The clone is disposable: nothing depends on it after install. You get the
newest **release** — the installer checks the newest release tag out
before installing and prints which one — so a fresh install and
`claude-sandbox update` (step 6) always agree on what "current" means.

### 5. Run Claude

```bash
claude
```

Log in when prompted (once; the login persists via the mount from
step 3). To let Claude push to a forge, authenticate with a
short-lived, single-repo token:

```bash
claude-sandbox gh-auth                    # GitHub
claude-sandbox glab-auth                  # Diamond GitLab
```

See [Authenticate with forges](../how-to/authenticate-with-forges.md)
for the recommended token shape.

### 6. Stay current

```bash
claude-sandbox version    # what you have
claude-sandbox update     # upgrade to the latest release
```

## Further reading

[Further reading for DLS](further-reading.md) collects what this page
deliberately leaves out: getting Claude into every devcontainer
automatically, what the three devcontainer.json items do, and the other
supported routes. The full documentation set starts at the
[documentation home](../index.md).
