[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![Docs](https://img.shields.io/badge/docs-online-blue.svg)](https://gilesknap.github.io/claude-sandbox/)

# claude-sandbox

bwrap-isolated Claude Code for Debian/Ubuntu devcontainers (rootless Podman is
the supported runtime; rootless Docker works too). A hostile prompt, file, or
tool result cannot reach your host credentials, IDE bridges, or shell
environment. The protection is launch-time: plain `claude` resolves to a shadow
that wraps the real binary in `bwrap`, and a global integrity guard fails loud
and closed if it is ever launched unwrapped.

📖 **Documentation: <https://gilesknap.github.io/claude-sandbox/>**

## Install

Inside any Debian/Ubuntu devcontainer (running as `root`, the typical
rootless-podman pattern):

```
git clone https://github.com/gilesknap/claude-sandbox.git
cd claude-sandbox
./install
```

Then run `claude` as usual — the shadow on `$PATH` wraps every invocation. The
installer is idempotent; wire `bash <clone>/install` into your devcontainer's
`postCreate.sh` to re-establish it on every rebuild.

The [getting-started tutorial][tutorial] has the full walkthrough, including the
`/user-terminal-config` clone location for `python-copier-template`
devcontainers and how to confirm the install with `/verify-sandbox`.

## What you get

- A shadow `claude` that wraps the real binary in `bwrap` (`--ro-bind / /`,
  `--tmpfs $HOME`, `--clearenv`, `--cap-drop ALL`, PID/IPC/UTS namespaces,
  TIOCSTI defence) so host credentials and IDE bridges are unreachable.
- A per-process **egress jail** (ADR 0015, on by default) that runs Claude in
  its own network namespace and blackholes RFC1918 (internal LANs, lab devices)
  while leaving the internet, DNS, and configured `allow-ip` devices reachable —
  so a compromised session can't pivot sideways to internal hosts. Fail-closed
  (needs `--device=/dev/net/tun`); `CLAUDE_SANDBOX_EGRESS_JAIL=0` opts out.
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
| [How-to guides][howto] | Verify, authenticate forges, configure workspace scope, configure the egress jail, promote, upgrade. |
| [Reference][reference] | Locked-down defences, the egress jail, the verification checks, config keys, deliberate exposures. |
| [Explanations][explain] | Threat model, architecture, the integrity guard, sandbox internals. |

## Development

```
bash tests/bwrap_argv.sh
bash tests/smoke.sh
bash tests/promote.sh
```

The same three commands CI runs — bash all the way down, no `uv`/pytest (see the
[contributing guide][contribute]). The repo's own `.claude/` is the canonical
source of the skills and commands the installer ships into target workspaces.
The docs live in `docs/` — the one isolated Python toolchain — and publish to
GitHub Pages on every push to `main`.

## License

See [`LICENSE`](./LICENSE).

[tutorial]: https://gilesknap.github.io/claude-sandbox/tutorials/getting-started.html
[howto]: https://gilesknap.github.io/claude-sandbox/how-to.html
[reference]: https://gilesknap.github.io/claude-sandbox/reference.html
[explain]: https://gilesknap.github.io/claude-sandbox/explanations.html
[arch]: https://gilesknap.github.io/claude-sandbox/explanations/architecture.html
[threat]: https://gilesknap.github.io/claude-sandbox/explanations/threat-model.html
[jail]: https://gilesknap.github.io/claude-sandbox/explanations/decisions/0015-network-egress-jail.html
[contribute]: https://gilesknap.github.io/claude-sandbox/how-to/contribute.html
