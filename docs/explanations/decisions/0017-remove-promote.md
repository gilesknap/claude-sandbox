(adr-remove-promote)=

# 17. Remove `just promote`; the sandbox keeps one auditable home

Date: 2026-07-24

## Status

Accepted

Supersedes {ref}`adr-promote-by-value` (ADR 10).

## Context

`just promote` ({ref}`adr-promote-by-value`, ADR 10) copied the
security-critical machinery — `install.sh`, `claude-shadow`, the guard
scripts, the verify battery — **by value** into target workspaces, so a
teammate cloning the target needed nothing but the devcontainer. ADR 10
valued two properties: self-sufficiency and a frozen audit surface
("what ran is what's at this SHA").

Living with it inverted that judgment:

- **Frozen copies are frozen vulnerabilities.** A security fix landed in
  this repo never reaches a promoted target unless someone remembers to
  re-promote, and nothing signals staleness — unlike the container
  launcher's notify-only version check. Drift is invisible exactly where
  it matters most.
- **It recreates the copy-per-project shape {ref}`adr-standalone-repo`
  (ADR 3) walked away from.** The repo exists because a security tool
  needs one canonical, audit-friendly home; promote re-proliferated it,
  push-driven instead of template-driven.
- **It widens the attack surface {ref}`adr-guard-restamp-anchor` (ADR 16)
  identified.** Promote shipped the trust-anchor guard scripts into every
  promoted target's *writable* workspace, multiplying the places where
  planted tamper could wait for a rebuild to bless it.
- **The other consumers cover the real use cases.** A project
  devcontainer gets the same result from one `postCreate` line that
  clones this repo at a pinned tag and runs `./install` — the target
  carries a reference, not ~1,500 lines of machinery. Everyone else has
  the published container image.

## Decision

Remove promote entirely: `promote.sh`, `tests/promote.sh`, the CI step,
the `justfile` recipe, and the how-to. Projects that want the sandbox
**reference** this repo instead of embedding it — a `postCreate` clone at
a pinned tag ([Sandbox a team devcontainer](../../how-to/sandbox-a-team-devcontainer.md)),
or the container image. Pinning the tag keeps ADR 10's "what ran is
what's at this SHA" property; upgrading becomes a deliberate,
reviewable pin bump instead of a forgotten re-promote.

## Consequences

- `justfile` recipes are no longer constrained to be promote-target-safe;
  the file is dev-tooling for this repo only.
- `install.sh` keeps its source guard
  (`[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"`) — the container image
  build sources it through the same seam.
- ADR 10's companion principle — keep **dogfood ≈ guest**, prefer
  `install.sh` over devcontainer wiring so a clone+install inside any
  devcontainer gets fixes for free — survives unchanged; it is about the
  installer, not promote, and is now load-bearing for the pinned-tag path
  too.
- ADR 10's other discipline — never auto-edit `devcontainer.json` (JSONC
  in the wild; print a snippet, trust the user) — also outlives the
  mechanism and applies to the pinned-tag how-to.
- The one property lost is offline self-sufficiency: a promoted target
  worked from `git clone <target>` alone. The pinned-tag path needs
  GitHub reachable at container-create time, which devcontainer creation
  effectively requires anyway. An air-gapped consumer would have to
  vendor the repo deliberately — accepted; no such consumer exists.
