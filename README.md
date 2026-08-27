[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![Docs](https://img.shields.io/badge/docs-online-blue.svg)](https://diamondlightsource.github.io/claude-sandbox/)

> **Active development has moved.** The project's primary home is now the Diamond
> Light Source fork: **[DiamondLightSource/claude-sandbox](https://github.com/DiamondLightSource/claude-sandbox)**.
> That repo has the latest features, documentation, and the published container
> image. This repository is the original home and may lag behind — for the current
> version, head there.

# claude-sandbox

bwrap-isolated Claude Code for Debian/Ubuntu devcontainers (rootless Podman is
the supported runtime; rootless Docker likely works but is untested with the
default egress jail). A hostile prompt, file, or
tool result cannot reach your host credentials, IDE bridges, or shell
environment. The protection is launch-time: plain `claude` resolves to a shadow
that wraps the real binary in `bwrap`, and a global integrity guard fails loud
and closed if it is ever launched unwrapped.

📖 **Documentation: <https://diamondlightsource.github.io/claude-sandbox/>**

## Why Use Claude Sandbox

Agents are vulnerable to prompt injection embedded in the text they process (web pages, commit messages etc). This can allow a bad actor to take control of your agent. Agents can also make mistakes.

The blast radius for badly behaved agents can be very large when they are running as a user whose credentials are within their reach. All your credentials are often available to an agent running under your account on your workstation.

For this reason Claude code will default to asking for user approval for every tool call it is going to make. But in real use this leads to 'approval fatigue' where users stop checking what the agent is about to do. 'auto-mode' is a partial fix for this as a second agent acts as a classifier for all tool calls and approves those that don't look dangerous. Unfortunately auto-mode has been demonstrated to be defeated by careful prompt injection.

Hence, Anthropic recommend running Claude Code in an isolated environment where it does not have access to your credentials and you carefully control what network devices and filesystem folders it does have access to. claude-sandbox allows you to have that control inside a developer container running locally on your workstation.

This report demonstrates key sandbox isolation properties: https://gist.github.com/gilesknap/582a289874e65b89fc99f09df37cf121.



## Install

Inside any Debian/Ubuntu devcontainer (running as `root`, the typical
rootless-podman pattern):

```
cd /tmp && rm -rf claude-sandbox && git clone https://github.com/DiamondLightSource/claude-sandbox && claude-sandbox/install
```

This installs the newest **release**, not the tip of `main` — `install`
checks the newest release tag out first and prints which one it picked
(`--here` installs the checkout as-is; `--release REF` picks a specific
one).

Then run `claude` as usual — the shadow on `$PATH` wraps every invocation.
Nothing depends on the clone after install, so a clone in `/tmp` is fine —
it evaporates with the container. The installer is idempotent; wire the
same one-liner into your devcontainer's `postCreate.sh` to re-establish it
on every rebuild (or clone at a pinned tag for a reviewable rollout — see
the [team how-to][team-howto]). Afterwards, `claude-sandbox update`
upgrades to the latest release and `claude-sandbox version` reports what
you have.

The [getting-started tutorial][tutorial] has the full walkthrough, including the
`/user-terminal-config` clone location for `python-copier-template`
devcontainers.

### Not a devcontainer user? Prebuilt image

A published image (`ghcr.io/diamondlightsource/claude-sandbox`) ships the whole sandbox
pre-installed — any Linux host with rootless podman can run sandboxed Claude
Code with no devcontainer and no root access (docker is untested with the
egress jail):

```bash
curl -fsSLO https://raw.githubusercontent.com/DiamondLightSource/claude-sandbox/main/container/claude-container
chmod +x claude-container
cd ~/src/my-project && ./claude-container
```

The launcher runs unsandboxed on your host — it is ~200 lines of bash; read it
before you run it. See [Use the prebuilt container image][container] for
pinning the fetch to a fixed ref, persistence, forge auth, and configuration;
each image records the launcher version it was tested with, and
`claude-container` tells you when your copy is out of date.

## What you get

- A shadow `claude` that wraps the real binary in `bwrap` (`--ro-bind / /`,
  `--tmpfs $HOME`, `--clearenv`, `--cap-drop ALL`, PID/IPC/UTS namespaces,
  TIOCSTI defence) so host credentials and IDE bridges are unreachable.
- A per-process **egress jail** (ADR 0015, on by default) that runs Claude in
  its own network namespace and blackholes RFC1918 (internal LANs, lab devices)
  while leaving the internet, DNS, and configured `allow-ip` devices reachable —
  so a compromised session can't pivot sideways to internal hosts. Fail-closed
  (needs `--device=/dev/net/tun`).
- A global, tamper-resistant **integrity guard** (highest-precedence
  managed-settings hooks + a disabled auto-updater) that fails loud and closed
  if Claude is ever launched outside the shadow.
- **Refusal-on-failure**: if the host can't run unprivileged user namespaces the
  installer refuses, rather than install a sandbox that isn't one.

How and why it works: the [architecture overview][arch], the
[threat model][threat], and the [network egress jail decision (ADR 0015)][jail].

## Documentation

| | |
|---|---|
| [Tutorial][tutorial] | Get to a working, verified sandbox. |
| [How-to guides][howto] | Verify, authenticate forges, configure workspace scope, configure the egress jail, sandbox a team devcontainer, upgrade. |
| [Reference][reference] | Locked-down defences, the egress jail, the verification checks, config keys, deliberate exposures. |
| [Explanations][explain] | Threat model, architecture, the integrity guard, sandbox internals. |

## Development

```
bash tests/bwrap_argv.sh
bash tests/smoke.sh
```

The same two commands CI runs — bash all the way down, no `uv`/pytest (see the
[contributing guide][contribute]). The repo's own `.claude/` is the canonical
source of the skills and commands the installer ships into target workspaces.
The docs live in `docs/` — the one isolated Python toolchain — and publish to
GitHub Pages on every push to `main`.

## License

See [`LICENSE`](./LICENSE).

[tutorial]: https://diamondlightsource.github.io/claude-sandbox/tutorials/getting-started.html
[team-howto]: https://diamondlightsource.github.io/claude-sandbox/how-to/sandbox-a-team-devcontainer.html
[howto]: https://diamondlightsource.github.io/claude-sandbox/how-to.html
[reference]: https://diamondlightsource.github.io/claude-sandbox/reference.html
[explain]: https://diamondlightsource.github.io/claude-sandbox/explanations.html
[arch]: https://diamondlightsource.github.io/claude-sandbox/explanations/architecture.html
[threat]: https://diamondlightsource.github.io/claude-sandbox/explanations/threat-model.html
[jail]: https://diamondlightsource.github.io/claude-sandbox/explanations/decisions/0015-network-egress-jail.html
[contribute]: https://diamondlightsource.github.io/claude-sandbox/how-to/contribute.html
[container]: https://diamondlightsource.github.io/claude-sandbox/how-to/use-the-container-image.html
