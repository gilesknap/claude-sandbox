(adr-guard-restamp-anchor)=

# 16. The integrity guard's re-stamp trust anchor must live outside the workspace

Date: 2026-06-19

## Status

Accepted

Records a tamper vector that {ref}`adr-managed-settings-guard` (ADR 13) and
{ref}`adr-integrity-surfaces` (ADR 14) do **not** close, and generalises the
conf-only gap tracked in issue #35 (noted in {ref}`adr-untrusted-workspace`,
ADR 12) to the guard scripts and the shadow. This ADR fixes the *design
constraint*; it deliberately does **not** ship the implementation — see
Consequences. Surfaced by the 2026-06-19 deep review (issue #63, finding H2).

## Context

ADR 13 puts the integrity guard (`sandbox-verify.sh`, `sandbox-gate.sh`) and
the shadow `claude` in root-owned, managed locations (`/usr/libexec`,
`/usr/local/bin`, `/etc/claude-code/`). In-session that property holds: those
paths are read-only from inside the bwrap jail, so a confined Claude cannot
rewrite the *running* guard. The deep review confirmed that protection is
intact.

The gap is **cross-session, at install time**. `install.sh` derives every
managed artifact from `$SCRIPT_DIR`:

```
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # install.sh:25
...
install_file "$SCRIPT_DIR/sandbox-verify.sh" ...             # :316
install_file "$SCRIPT_DIR/sandbox-gate.sh"   ...             # :317
install_file "$SCRIPT_DIR/claude-shadow"     ...             # :433
```

`$SCRIPT_DIR` resolves into the **read-write workspace clone**
(`.devcontainer/claude-sandbox/`), which a confined Claude can edit. The
managed copies are protected in-session, but on the *next* container
(re)build `postCreate.sh` → `bash install` re-stamps the workspace copies over
the root-owned guard and shadow with **no provenance, hash, or signature
check** (`install_file`, install.sh:127). A session that edits its own
`sandbox-gate.sh` to `exit 0`, or its `claude-shadow` to drop `--unshare-net`
or widen a bind, plants tamper that the next rebuild promotes to the trusted,
root-owned guard. The verifier and gate cannot catch it — they assert
`IS_SANDBOX=1` and a clean env, and the verifier *is* the re-stamped script.
{ref}`adr-promote-by-value` (ADR 10) widens the reach: `promote.sh` ships these
same files into every promoted target's writable workspace.

This is strictly more severe than the `/etc/claude-sandbox.conf` re-stamp
already filed as issue #35: the conf only carries configuration, whereas the
guard scripts and the shadow are the *enforcement itself*.

**Why a naive in-tree fix does not work.** The obvious patch — have
`install.sh` verify each source against a pinned hash and refuse to re-stamp on
mismatch — only relocates the question to *where the reference lives*:

- A hash **committed to the repo** (e.g. a `SHA256SUMS` file) sits in the same
  writable tree; a confined Claude edits the script and the checksum together.
- A hash **baked into the container image** at `docker build` is regenerated
  from the image's build context, which *is* the workspace tree. The very
  "rebuild" the threat assumes — an operator rebuilding the image from a tree a
  prior session poisoned — regenerates the reference from the poison. It would
  catch only a container *recreate that reuses the existing image*, not an
  image rebuild; and "rebuild" is exactly the scenario in Context.
- "Trust on first use, refuse silent divergence" needs the prior trusted copy
  to survive a rebuild, which again means baking it into the image (same
  limitation), and it blocks legitimate maintainer edits without an
  out-of-band blessing.

The common thread: **the trust anchor cannot live anywhere the confined
session — or a rebuild driven from the workspace it poisoned — can reach.** A
robust anchor must be *outside the workspace tree entirely*.

## Decision

1. The integrity guard's source-of-truth at install time MUST be anchored
   outside the writable workspace. An in-tree hash/checksum is **not**
   acceptable as the sole control, because the same actor that can poison the
   script can poison the reference.
2. The leading candidate is an **upstream-pinned anchor**: `install.sh` obtains
   the canonical `sandbox-verify.sh`, `sandbox-gate.sh`, and `claude-shadow`
   (or their checksums) from the upstream repository at a commit SHA pinned in
   the image/`Dockerfile`, and installs/verifies from *that*, refusing a
   divergent workspace copy. Subverting it then requires push access to the
   upstream repo, not merely write access to the local clone. Install runs in
   `postCreate`, before the egress jail wraps `claude`
   ({ref}`adr-network-egress-jail`, ADR 15), so it has normal container network
   for the fetch.
3. Local development of the guard files MUST remain possible via an explicit,
   **host-controlled** opt-out — an env or flag a confined session cannot set,
   the same class of out-of-tree signal used to harden the gate escape hatch
   (a root-owned `/etc` flag; issue #63, finding H4) — so editing a guard file
   does not require pushing and re-pinning first.
4. We deliberately **do not** ship a partial in-tree hash check now. A
   half-measure that fails open on an image rebuild reads as "closed" on a
   green build while leaving the real path open — worse than an honest, tracked
   gap.

## Consequences

- No code change lands with this ADR. The re-stamp vector remains open on
  `main`; it is now recorded here (superseding the conf-only framing of issue
  #35) rather than left implicit.
- A follow-up ADR + implementation will specify the out-of-tree anchor (the
  upstream-pinned candidate or a better mechanism), the pinned-SHA bump
  workflow, the host-only local-dev opt-out, and the failure mode when the
  network or upstream is unreachable at install — which MUST fail closed
  (refuse to re-stamp) rather than fall back to the workspace copy.
- Operators should, in the meantime, treat a container/image rebuild as a
  trust event: review the `.devcontainer/claude-sandbox/` diff (or rebuild from
  a clean checkout) before rebuilding after an untrusted session. This guidance
  belongs in the threat model.
- The in-session protection from ADR 13/14 is unaffected and remains the
  primary control; this ADR concerns only the cross-session install path.
