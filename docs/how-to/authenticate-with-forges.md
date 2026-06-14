# Authenticate with forges

Give the sandboxed Claude a `gh` / `glab` token so `git push` works,
without leaking the token into your shell history.

## Authenticate

```bash
just gh-auth
just glab-auth
just glab-auth gitlab.diamond.ac.uk
```

- `just gh-auth` authenticates `github.com`.
- `just glab-auth` (no argument) authenticates `gitlab.com`.
- `just glab-auth gitlab.diamond.ac.uk` authenticates the self-hosted
  Diamond GitLab instance.

Each recipe walks you through a fine-grained-PAT prompt, feeds the token
to the respective CLI's `auth login`, and unsets the variable
afterwards. The token never enters shell history.

## Result

The CLI's token store (`~/.config/gh/` or `~/.config/glab-cli/`) is
bound read-write into the sandbox, and the curated gitconfig uses the
CLI as a git credential helper, so `git push` authenticates without an
OAuth popup.

## Recommended PAT shape

The token is reachable by a compromised session, so keep its blast
radius small:

- **Fine-grained, single repo** — grant write access only to the
  repository you are actively working on.
- **Short expiry** — 7–30 days. Re-pasting via `just gh-auth` takes
  seconds.
- **No `workflow` scope** unless Claude needs to edit GitHub Actions
  files. **No `admin:*` or org-wide write scopes.**
- **GitLab** — equivalent fine-grained project tokens; `api` scope only
  if you need push, otherwise `read_repository` + `write_repository`.

`just gh-auth` / `just glab-auth` keep the token out of shell history
but do **not** enforce scope discipline — that is yours.

## See also

- [Threat model](../explanations/threat-model.md) — why PAT hygiene
  matters and what a leaked token can reach.
- [Run without push access](run-without-push-access.md) — skip the token
  binds entirely for sessions where Claude does not need to push.
