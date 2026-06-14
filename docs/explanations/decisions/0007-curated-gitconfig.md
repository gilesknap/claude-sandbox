(adr-curated-gitconfig)=

# 7. Redirect git to a curated gitconfig rather than masking the host's

Date: 2026-05-11

## Status

Accepted

## Context

Inside the sandbox, git needs to (a) use the `gh`/`glab` credential helpers so
`git push` authenticates (see {ref}`adr-container-scoped-credentials`), (b)
apply ssh→https `insteadOf` rewrites, and (c) not pick up the host's personal
git identity or system config. The first implementation bind-**masked** the host
gitconfigs (`/etc/gitconfig`, `~/.gitconfig`) with `/dev/null` as
defence-in-depth. That broke tools which scrub `GIT_*` env vars before spawning
git (e.g. pre-commit's `no_git_env`): they fell through to the masked, empty
config — and the mask added no protection beyond the env redirect.

## Decision

Redirect git by **environment, not by masking the host files**. The shadow sets
`GIT_CONFIG_GLOBAL=/etc/claude-gitconfig` and `GIT_CONFIG_SYSTEM=/dev/null`, and
**regenerates** `/etc/claude-gitconfig` on every launch from the host's current
`user.name`/`user.email` — wiring the `gh`/`glab` credential helpers and the
ssh→https `insteadOf` rewrites. The host's `/etc/gitconfig` stays *readable* but
is neutralised for git by the `GIT_CONFIG_SYSTEM=/dev/null` redirect; the host's
`~/.gitconfig` is invisible anyway under the strict-under-`/root` inversion
({ref}`adr-bwrap-isolation`). Commit `b1dd6df` walked back the earlier
bind-mask; `ad69881` made the regeneration per-launch.

## Consequences

- A host gitconfig identity edit takes effect on the next `claude` launch with
  nothing to re-run.
- Tools that scrub `GIT_*` see the host `/etc/gitconfig` — intended. The env
  redirect, not a bind-mask, is the boundary.
- `CLAUDE_SANDBOX_NO_FORGE=1` drops the credential helpers from the generated
  config (see {ref}`adr-container-scoped-credentials`).
- The generator is untested logic inlined in the launch body, and the forge host
  set is hard-coded (the `glab` helper covers only `gitlab.diamond.ac.uk` while
  `just glab-auth` defaults to `gitlab.com`). Both are tracked in issue #49.
