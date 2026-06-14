(adr-promote-by-value)=

# 9. `just promote` copies by value and never edits devcontainer.json

Date: 2026-05-12

## Status

Accepted

## Context

`just promote <target>` (issue #18, PR #20) makes any workspace a self-sufficient
claude-sandbox host. Two natural-sounding refinements were considered and
declined: (a) auto-editing the target's `devcontainer.json` to wire the
`postCreate` line; (b) pointing the target's `postCreate.sh` at the shared
canonical clone instead of copying the install machinery in (PR #24).

## Decision

Promote copies the install machinery **by value** into the target (curated
`.claude/`, `.devcontainer/claude-sandbox/`, the root `justfile`), then **prints**
a one-line `postCreateCommand` snippet for the user to paste — it does **not**
edit `devcontainer.json`. That file is JSONC in the wild; comment-preserving
structured edits need either ~50 lines of state-tracking awk or a node/python
dependency, both rejected. Reference-by-shared-clone is declined too: copy-by-
value buys **self-sufficiency** (`git clone <target> && ./install` works on CI
runners, clean VMs, and collaborators' layouts) and a **frozen audit surface**
("what ran is what's at this SHA"), whereas reference-by-path runs whatever HEAD
the shared clone happens to be at.

## Consequences

- A companion principle — keep **dogfood ≈ guest**: a fix that could live in
  either `install.sh` or `devcontainer.json`/`postCreate.sh` goes in
  `install.sh`, so a clone+install inside any unrelated devcontainer gets it for
  free and the audit surface stays single-track.
- The shipped `justfile` runs verbatim in targets, so source-repo-only recipes
  (`test`, `verify`, `upgrade`) were dropped.
- Refuse, without surfacing the trade-off: auto-editing `devcontainer.json`; and
  "just point `postCreate` at the shared clone." An *opt-in* recipe alongside
  the frozen-copy default is the only acceptable compromise — never "keep both
  mechanisms and sync them," which is exactly the synchronisation debt
  {ref}`adr-standalone-repo` walked away from.
