# Authenticate with forges

Give the sandboxed Claude a `gh` / `glab` token so `git push` works,
without leaking the token into your shell history.

## Authenticate

```bash
claude-sandbox gh-auth
claude-sandbox glab-auth
claude-sandbox glab-auth gitlab.example.com
```

- `claude-sandbox gh-auth` authenticates `github.com`.
- `claude-sandbox glab-auth` (no argument) authenticates the self-hosted
  Diamond GitLab instance, `gitlab.diamond.ac.uk`.
- `claude-sandbox glab-auth gitlab.example.com` authenticates any other
  GitLab instance (including `gitlab.com`).

Each command walks you through a fine-grained-PAT prompt, feeds the
token to the respective CLI's `auth login`, and unsets the variable
afterwards. The token never enters shell history.

## Result

The CLI's token store (`~/.config/gh/` or `~/.config/glab-cli/`) is
bound read-write into the sandbox, and the curated gitconfig uses the
CLI as a git credential helper, so `git push` authenticates without an
OAuth popup.

> **Internal (RFC1918) forge?** With the egress jail on (the default),
> pushing to a forge on an internal IP also needs that IP punched
> through the RFC1918 blackhole via `allow-ip` in
> `/etc/claude-sandbox.conf` — otherwise authentication succeeds but the
> push fails at the network layer. The shipped conf already allows
> Diamond's GitLab (`172.23.142.119`); for a different internal forge
> see [Configure the network egress jail](network-egress-jail.md).

## Recommended PAT shape

The token is reachable by a compromised session, so keep its blast
radius small:

- **Fine-grained, single repo** — grant write access only to the
  repository you are actively working on.
- **Short expiry** — 7–30 days. Re-pasting via `claude-sandbox gh-auth`
  takes seconds.
- **No `workflow` scope** unless Claude needs to edit GitHub Actions
  files. **No `admin:*` or org-wide write scopes.**
- **GitLab** — equivalent fine-grained project tokens; `api` scope only
  if you need push, otherwise `read_repository` + `write_repository`.

`claude-sandbox gh-auth` / `claude-sandbox glab-auth` keep the token out
of shell history but do **not** enforce scope discipline — that is
yours.

## See also

- [Threat model](../explanations/threat-model.md) — why PAT hygiene
  matters and what a leaked token can reach.
- [Run without push access](run-without-push-access.md) — skip the token
  binds entirely for sessions where Claude does not need to push.
