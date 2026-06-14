# claude-sandbox

Bash-only. No Python package, no uv, no pytest — don't add them back.

The **one** allowed Python is the documentation toolchain, fully isolated
to `docs/` (`docs/requirements.txt`: Sphinx + MyST + pydata theme + mermaid).
It builds `docs/` to HTML for GitHub Pages and touches nothing in the
security-critical core — no `pyproject.toml`, no `uv.lock`, no `src/`, no
pytest, no docs recipe in the shipped `justfile`. Don't let it grow past
that boundary.

- Docs (Diátaxis, Sphinx): `docs/` → published to GitHub Pages by
  `.github/workflows/docs.yml`. Build locally: `python -m venv .venv-docs
  && .venv-docs/bin/pip install -r docs/requirements.txt && .venv-docs/bin/sphinx-build -b html docs build/html`
- Threat model + sandbox model: `README-CLAUDE.md`
- Sandbox-integrity spec: `.claude/commands/verify-sandbox.md`
