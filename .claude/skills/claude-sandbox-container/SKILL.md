---
name: claude-sandbox-container
description: Design decisions for the published container image `ghcr.io/diamondlightsource/claude-sandbox` and its host-side launcher. Covers image-build-sources-install.sh (never a parallel install path), entrypoint re-runs of build-time skips, named-container PAT scoping, ro-mounted conf, tag-vs-latest publishing, notify-only launcher versioning (refuse --self-update), and parked issues #79/#80/#81. Surface before edits to the root Dockerfile, container/entrypoint.sh, container/claude-container, or .github/workflows/container.yml. Core shadow/installer invariants live in the claude-sandbox skill.
---

# claude-sandbox-container

The published container image is the **third consumer** of the sandbox
(after the dogfood devcontainer and guest clone+install — see "dogfood ≈
guest" in the `claude-sandbox` skill, whose Invariants 2 and 4 are
mapped onto the image below). Split from that skill so this loads only
on image/launcher topics.

## The image (PR #78)

`ghcr.io/diamondlightsource/claude-sandbox` (built by `.github/workflows/container.yml`
from the root Dockerfile's `claude-sandbox` stage, `FROM` the `developer`
stage) gives non-devcontainer hosts sandboxed Claude via rootless podman + the
`container/claude-container` launcher. Principles already extended here:

- **Dogfood ≈ guest ≈ image**: the image build *sources* `install.sh` and runs
  main()'s function sequence — never a parallel install path. Two deliberate
  build-time skips (both re-run by `container/entrypoint.sh` at start):
  `probe_userns_or_refuse` (a builder probe proves nothing about the runtime
  host) and `link_terminal_config` — the DLS base ships an EMPTY
  `/user-terminal-config` stub, and wiring it at build symlinks
  `~/.claude.json` to a zero-length file the official installer rejects as
  corrupted JSON ("Unexpected EOF"). The entrypoint also seeds `{}` into a
  zero-length `~/.claude.json` (same hazard, first run with a fresh share).
- **Invariant 2 mapping**: the launcher creates one NAMED container per
  project dir (`podman create` once, `start -ai` after) so forge PATs are
  container-scoped without per-launch re-paste; `--recreate` ⇒ re-auth. Refuse
  a "just mount host ~/.config/gh" convenience swap.
- **Invariant 4 mapping**: durable user conf = host file ro-mounted at the
  canonical `/etc/claude-sandbox.conf`; the entrypoint detects the mount
  (`_is_mount`) and skips re-stamping. Conf stays outside the sandbox rw set.
- A git tag publishes `ghcr.io/...:<tag>` without touching `:latest`
  (`latest` is default-branch-only) — beta images are safe to cut anytime.
- **Launcher versioning (notify-only, by design)**: the `VERSION=` line
  in `container/claude-container` is the single source of truth; CI seds
  it into the Dockerfile `ARG` → OCI label
  `io.diamondlightsource.claude-sandbox.launcher-version`, and a CI step asserts
  label == baked script. Each run the launcher compares itself against
  the LOCAL image's label (instant, offline, no container start) and
  prints a curl pinned to `org.opencontainers.image.revision` when
  outdated, or a pull+`--recreate` hint when newer. **Refuse:** a
  `--self-update` flag (the launcher runs unsandboxed on the host —
  replacing it must stay a deliberate, reviewable act), and hard-failing
  the build on an empty `LAUNCHER_VERSION` ARG (the label is advisory;
  pre-label images exist and must degrade to silence — CodeRabbit asked,
  declined on PR #78). The label key was renamed from
  `io.gilesknap.…` in the DLS-org rebrand (2026-07-24); images built
  before then carry only the old key, so a new launcher reads an empty
  label and degrades to silence — expected, not a bug.
- **Distribution/conf decisions parked as issues** (re-read before
  re-designing any of these): **#79** ship `/verify-sandbox` as a plugin
  via managed settings — docs-verified that `extraKnownMarketplaces`
  (local path) + `enabledPlugins` is Claude Code's ONLY machine-wide
  command/skill channel (no system commands dir exists; command becomes
  namespaced `/claude-sandbox:verify-sandbox`). **#80** Renovate-pinned
  Claude version (official installer takes `[stable|latest|X.Y.Z]` as
  `$1`; `downloads.claude.ai/claude-code-releases/{latest,stable}`
  return bare version strings). **#81** per-project
  `.claude-sandbox.conf` — see the Invariant 4 carve-out in the
  `claude-sandbox` skill.
