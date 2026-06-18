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
- **Never merge a docs layout/CSS change until the user has verified the
  rendering locally in a real browser.** The user verifies via autobuild
  (`just docs` / `sphinx-autobuild`) at multiple widths; the sandbox has no
  browser and WeasyPrint is not a faithful proxy for Chromium auto-layout.
  Open the PR if asked, but wait for the user's explicit OK before merging —
  don't merge on a green build alone.
- Threat model + sandbox model: `README-CLAUDE.md`
- Sandbox-integrity spec: `.claude/commands/verify-sandbox.md`
- Network egress jail (lateral-movement isolation, ADR 0015):
  `docs/explanations/decisions/0015-network-egress-jail.md`; operational skill:
  `.claude/skills/claude-sandbox-networking/SKILL.md`
