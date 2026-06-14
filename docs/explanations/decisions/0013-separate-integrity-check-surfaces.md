(adr-integrity-surfaces)=

# 13. Keep the integrity-check surfaces separate and self-contained

Date: 2026-06-14

## Status

Accepted

## Context

The question "is Claude actually inside the bwrap shadow, and is the sandbox
intact?" is answered in three places:

- `sandbox-gate.sh` — the `UserPromptSubmit` fail-closed gate; a single
  `IS_SANDBOX=1` compare, lean by design.
- `sandbox-verify.sh` — the `SessionStart` advisory verifier; `IS_SANDBOX` plus
  nine inline integrity assertions (no token leak, the gitconfig redirect is in
  effect, `/run/secrets` empty, …).
- `.claude/commands/verify-sandbox.md` — the `/verify-sandbox` spec: the full
  18-check deterministic battery (of which the verifier's nine are a subset)
  plus 10 LLM-driven adversarial probes.

A natural architecture review flags the overlap as duplication and proposes
extracting a shared integrity-check module so the surfaces cannot drift. That
would conflict with the project's load-bearing self-containment principle —
`claude-shadow` deliberately inlines its argv builder rather than sourcing a
library "so the shadow is a single file you can read top-to-bottom" — and it
would couple `verify-sandbox.md`, whose value is being a standalone,
human-readable summary of the threat model with per-check rationale, to an
implementation file.

## Decision

Keep the three surfaces as separate, self-contained artifacts. Do not extract a
shared integrity-check module, and do not mechanically de-duplicate
`verify-sandbox.md` against `sandbox-verify.sh`.

Credential isolation is *decided* in `bwrap_argv_build`'s `--clearenv`
allow-list, not in the advisory `SessionStart` hook. Coverage for it therefore
belongs at the argv-builder layer — negative assertions in
`tests/bwrap_argv.sh` that a credential variable present in the environment
never appears as a `--setenv` in the built argv — not in a tested copy of the
hook.

## Consequences

- The verifier's nine assertions stay a hand-maintained subset of the
  `/verify-sandbox` battery. Drift is accepted: the verifier is a third,
  advisory line of defence (the gate fail-closes on `IS_SANDBOX`;
  `/verify-sandbox` is the authoritative live battery), so a stale or buggy
  assertion costs at most a missed warning, not an open door. With an LLM
  maintainer, reconciling the subset against the full spec is cheap.
- `verify-sandbox.md` stays optimised for human auditability.
- A future architecture pass should not re-suggest a shared integrity-check
  module on DRY grounds alone — that trade-off was considered and declined here.
- Follow-up, separate from this decision: add credential-scrub negative
  assertions to `tests/bwrap_argv.sh`, which today carries no `assert_not_contains`
  for `GH_TOKEN` / `GITHUB_TOKEN` / `ANTHROPIC_API_KEY` / `SSH_AUTH_SOCK`.
