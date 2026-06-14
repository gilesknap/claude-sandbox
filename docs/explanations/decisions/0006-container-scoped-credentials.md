(adr-container-scoped-credentials)=

# 6. Scope credentials to the container; re-paste PATs on every rebuild

Date: 2026-05-11

## Status

Accepted

## Context

Claude needs `gh`/`glab` to push code, so their token stores
(`~/.config/gh/`, `~/.config/glab-cli/`) are bound rw into the sandbox.
Fine-grained personal access tokens typically cover several repos, so any token
path persisted *across* devcontainers would let one compromised session reach
every repo that PAT touches.

## Decision

Keep PATs **container-scoped**. No persistent-credential mount — volume, bind,
or a re-purposed Docker `/cache` volume, anywhere — for `gh`/`glab` tokens. The
re-paste-on-rebuild ceremony (`just gh-auth` / `just glab-auth`) is the
deliberate cost of keeping the blast radius small. By contrast `~/.claude` and
`~/.claude.json` *are* cross-container (symlinked via `link_terminal_config`)
because they hold one Claude login, not repo-scoped credentials — don't conflate
the two.

## Consequences

- Rebuilds re-prompt for the PAT; `just gh-auth` makes that a few seconds and
  keeps the token out of shell history.
- PAT *scope* discipline (fine-grained, single-repo, short expiry) is the user's
  responsibility, documented under "PAT hygiene" in `README-CLAUDE.md`. The
  tool keeps the token off disk-history; it does not enforce scope.
- `CLAUDE_SANDBOX_NO_FORGE=1` skips the token binds (and the credential helpers)
  entirely when a session doesn't need to push.
- A "stop re-pasting the PAT" request must surface this trade-off before any
  shortcut is implemented.
