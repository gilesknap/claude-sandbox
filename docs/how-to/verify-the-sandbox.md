# Verify the sandbox

Confirm that the Claude process you are running is actually inside the
bwrap isolation, and that no defence has regressed.

```{include} ../_snippets/clone-note.md
```

## Run the verification

From inside a Claude session:

```bash
/verify-sandbox
```

This runs against the live process and prints a summary table.

## What it does

There are two phases:

1. **The PASS/FAIL battery** — 18 checks against the running process,
   one per defence (sandbox entered, capabilities dropped, namespaces
   unshared, IPC/secrets/runtime dirs masked, curated gitconfig in
   effect, and so on).
2. **Adversarial breakout probes** — 10 probes that run only once the
   battery passes, attempting actual breakout / disclosure paths.

The full spec lives at `.claude/commands/verify-sandbox.md`.

## Read the result

- Every line of the battery should report `PASS`.
- Any `FAIL` line names the specific defence that regressed.
- Probes may report `[INCONCLUSIVE]` for accepted information-disclosure
  paths (e.g. network-identity disclosure) — these are on the radar by
  design, not failures.

The command **exits non-zero on any FAIL**, so the same invocation
doubles as a CI assertion — wire it into a pipeline to fail the build
if the sandbox ever regresses.

## See also

- [Verification checks](../reference/verification-checks.md) — the full
  list of checks and what each one proves.
- [The integrity guard](../explanations/integrity-guard.md) — the
  always-on guard that re-runs the integrity subset every session and
  blocks prompts when Claude is unwrapped, so you do not have to run
  `/verify-sandbox` by hand to stay protected.
