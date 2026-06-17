# claude-sandbox recipes. Shipped verbatim into promoted targets via
# `just promote`, so every recipe here must be SAFE in both the source
# clone and a promoted host workspace. Dev-only recipes (e.g. `docs`)
# self-guard: they no-op where they don't apply rather than erroring.

# Seed the sandbox's curated `.claude/` (commands, skills) into a target
# host workspace. The integrity guard is global (wired into ~/.claude by
# install.sh), not seeded per-repo. See
# .devcontainer/claude-sandbox/promote.sh for the rationale.
promote target=invocation_directory():
    bash .devcontainer/claude-sandbox/promote.sh {{ target }}

# Authenticate gh CLI with a GitHub PAT (token not stored in shell history).
gh-auth:
    #!/usr/bin/env bash
    url=$'\e[4;36mhttps://github.com/settings/personal-access-tokens\e[0m'
    cat <<EOF
    Create or renew a fine-grained PAT at:
      $url

    Recommended settings for a sandboxed Claude Code:
      - Resource owner: your user (or org that owns this repo)
      - Repository access: Only select repositories -> just this repo
      - Expiration: short (e.g. 30 days) so a leaked token expires quickly
      - Repository permissions Read/Write:
          Issues, Pull requests
      - Repository permissions Read Only:
          Contents
        (Metadata: Read-only is added automatically)
      - Leave everything else unset / no access

    EOF
    read -sp "GitHub PAT: " t && echo
    echo "$t" | gh auth login --with-token
    unset t
    gh auth setup-git
    gh auth status

# Authenticate glab CLI with a GitLab PAT (token not stored in shell history).
# --git-protocol https prevents glab's SSH insteadOf rewrite.
glab-auth hostname="gitlab.com":
    #!/usr/bin/env bash
    url=$'\e[4;36mhttps://gitlab.com/-/user_settings/personal_access_tokens\e[0m'
    cat <<EOF
    Create or renew a fine-grained PAT at:
      $url
      (or your organisation's GitLab instance equivalent)

    Recommended scopes for a sandboxed Claude Code:
      - api, read_repository, write_repository
      - Short expiration so a leaked token expires quickly

    EOF
    read -sp "GitLab PAT for {{ hostname }}: " t && echo
    echo "$t" | glab auth login --stdin --hostname {{ hostname }} --git-protocol https
    unset t
    glab auth status

# Provisions an isolated .venv-docs on first run; no-ops where there is no
# docs/ Sphinx project, so it stays promote-target-safe.
# Live-reload preview of the docs/ site at http://localhost:<port>.
docs port="8000":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f docs/conf.py ] || [ ! -f docs/requirements.txt ]; then
        echo "No docs/{conf.py,requirements.txt} here — 'just docs' is a no-op in this workspace."
        exit 0
    fi
    # Re-provision if missing OR stale: the venv lives in the workspace mount
    # but its uv-managed interpreter lives outside it, so a container rebuild
    # leaves a dangling python symlink. Probe the interpreter, not just the
    # script file, or we'd skip the rebuild and die on exec (127).
    if ! .venv-docs/bin/python -c '' 2>/dev/null || [ ! -x .venv-docs/bin/sphinx-autobuild ]; then
        rm -rf .venv-docs
        uv venv .venv-docs
        uv pip install --python .venv-docs -r docs/requirements.txt sphinx-autobuild
    fi
    exec .venv-docs/bin/sphinx-autobuild docs build/html --port {{ port }}
