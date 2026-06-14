(adr-standalone-repo)=

# 3. Live in a standalone repo, extracted from python-copier-template

Date: 2026-05-10

## Status

Accepted

## Context

The sandbox originally lived embedded in `python-copier-template` as
`.devcontainer/claude-sandbox.sh` — a single bash script using `unshare -m` plus
tmpfs overlays. Carrying a security tool as a templated copy means one drifting
copy in every generated project and no canonical thing to audit or verify.

## Decision

Extract the sandbox into this standalone repository. A security tool needs **one
canonical, audit-friendly home** with its own CI, a versioned release surface,
and `/verify-sandbox` as a first-class command. The template should *consume*
this repo, not embed it.

## Consequences

- `python-copier-template`'s `.devcontainer/claude-sandbox.sh` remains as prior
  art but is **not** maintained.
- We refuse, without fresh justification, a `template/` directory or
  `copier.yml` here, and "let's keep a copy synced into python-copier-template."
- The underlying principle — *the sandbox's surface must stay small enough to
  audit in one read* — recurs as the driver behind {ref}`adr-bash-only`. The
  bwrap-based defences (see {ref}`adr-bwrap-isolation`) also replace the older
  `unshare -m` approach, which would have been awkward inside a per-project
  template.
