# Contribute to claude-sandbox

A task recipe for contributors. For the design rationale behind the
bash-only constraint and the sandbox itself, see the
[explanations](../explanations.md).

## File an issue or open a discussion

Issues and pull requests are handled through
[GitHub](https://github.com/gilesknap/claude-sandbox/issues). Check for an
existing issue before filing a new one.

- **Bug report or concrete change** → file an
  [issue](https://github.com/gilesknap/claude-sandbox/issues). If the change
  is large, file the issue *before* opening a pull request so the scope can be
  agreed first.
- **Open-ended question or idea** → if it isn't obvious when it could be
  "closed", raise it as a
  [discussion](https://github.com/gilesknap/claude-sandbox/discussions)
  instead.

## Respect the bash-only ethos

The tool is bash all the way down. There is **no Python package, no `uv`, and
no `pytest`** in the tool itself — do not add them back. The one isolated
Python dependency in the repo is the docs toolchain (see
[Build the docs locally](#build-the-docs-locally)); it does not make the tool
a Python project.

## Run the tests CI runs

Clone the repo and run the same three commands CI runs:

```bash
git clone https://github.com/gilesknap/claude-sandbox.git
cd claude-sandbox
bash tests/bwrap_argv.sh
bash tests/smoke.sh
bash tests/promote.sh
```

No `uv sync`, no pytest, no twine. Development is best done inside a
[vscode devcontainer](https://code.visualstudio.com/docs/devcontainers/containers);
the repository ships configuration for a containerised development
environment.

## Edit shipped skills, commands, and hooks

The repo's own `.claude/` **is the canonical source** of the skills,
commands, and hooks the installer ships. Editing one entry updates both how
Claude behaves on this repo *and* what
[`just promote`](../how-to/promote-to-a-workspace.md) lands in target workspaces — so make
those edits in `.claude/`, not in a copied target.

## Build the docs locally

The docs toolchain is the project's one isolated Python dependency, pinned in
`docs/requirements.txt`. The quickest way to preview is the `docs` recipe, which
provisions an isolated `.venv-docs` on first run and serves the site with live
reload:

```bash
just docs          # http://localhost:8000, rebuilds on save
just docs 9000     # choose a different port
```

Or build it once by hand into a throwaway virtualenv:

```bash
python -m venv venv
. venv/bin/activate
pip install -r docs/requirements.txt
sphinx-build -b html docs build/html
```

Open `build/html/index.html` to preview. CI builds with `-W` (warnings are
errors), so resolve any warning the local build prints.
