# Contribute to claude-sandbox

A task recipe for contributors. For the design rationale behind the
bash-only constraint and the sandbox itself, see the
[explanations](../explanations.md).

## File an issue or open a discussion

Issues and pull requests are handled through
[GitHub](https://github.com/DiamondLightSource/claude-sandbox/issues). Check for an
existing issue before filing a new one.

- **Bug report or concrete change** → file an
  [issue](https://github.com/DiamondLightSource/claude-sandbox/issues). If the change
  is large, file the issue *before* opening a pull request so the scope can be
  agreed first.
- **Open-ended question or idea** → if it isn't obvious when it could be
  "closed", raise it as a
  [discussion](https://github.com/DiamondLightSource/claude-sandbox/discussions)
  instead.

## Respect the bash-only ethos

The tool is bash all the way down. There is **no Python package, no `uv`, and
no `pytest`** in the tool itself — do not add them back. The one isolated
Python dependency in the repo is the docs toolchain (see
[Build the docs locally](#build-the-docs-locally)); it does not make the tool
a Python project.

## Run the tests CI runs

There is no task runner — the suites are plain bash, run directly from a
clone (or from this repo's own devcontainer):

```bash
CLAUDE_SANDBOX_SMOKE=1 bash tests/bwrap_argv.sh   # shadow's bwrap argv
CLAUDE_SANDBOX_SMOKE=1 bash tests/smoke.sh        # installer file placement
bash tests/install_ref.sh                         # which ref `install` picks
bash tests/egress_jail.sh                         # network egress jail
```

`CLAUDE_SANDBOX_SMOKE=1` keeps the first two off the network and out of
`/`; they install into a tmpdir instead. All four want **root** — which a
devcontainer already gives you, so no `sudo`; CI adds it because its
runner is not root. `tests/egress_jail.sh` needs
`CAP_NET_ADMIN` and its own network namespace, so it **skips** when run
from inside a sandboxed Claude session (namespaces can't nest there) —
run it from an unsandboxed devcontainer terminal. CI runs it with
`EGRESS_JAIL_REQUIRE=1`, which turns a skip into a failure.

No `uv sync`, no pytest, no twine.

To install the checkout you are working on, pass `--here`:

```bash
./install --here     # install THIS working tree
./install            # install the newest release tag instead
```

`install` defaults to the newest release tag, so that a user's first
install and their later `claude-sandbox update` agree on what "current"
means. On a feature branch, a detached checkout, or a dirty tree it
refuses rather than quietly discarding your work — `--here` is the answer
whenever you mean "install what I have".

Development is best done inside a
[vscode devcontainer](https://code.visualstudio.com/docs/devcontainers/containers);
the repository ships configuration for a containerised development
environment.

## Edit shipped skills, commands, and hooks

The repo's own `.claude/` **is the canonical source** of the skills,
commands, and hooks the installer ships — make edits there, in the clone.

## Build the docs locally

The docs toolchain is the project's one isolated Python dependency, pinned in
`docs/requirements.txt`. Nothing else here needs Python — and with
[uv](https://docs.astral.sh/uv/) you do not need one installed at all:
`uvx` fetches an interpreter and the pinned requirements into its own
throwaway environment, leaving no virtualenv in the repo.

For a live-reload preview:

```bash
uvx --with-requirements docs/requirements.txt --from sphinx-autobuild \
  sphinx-autobuild docs build/html --port 8000        # rebuilds on save
```

Or build once, exactly as CI does:

```bash
uvx --with-requirements docs/requirements.txt --from sphinx \
  sphinx-build -b html -W --keep-going docs build/html
```

Open `build/html/index.html` to preview. CI builds with `-W` (warnings are
errors), so resolve any warning the local build prints.

No `uv`? Install it
([one command](https://docs.astral.sh/uv/getting-started/installation/)), or
use a throwaway virtualenv instead:

```bash
python -m venv .venv-docs
.venv-docs/bin/pip install -r docs/requirements.txt sphinx-autobuild
.venv-docs/bin/sphinx-autobuild docs build/html --port 8000
```
