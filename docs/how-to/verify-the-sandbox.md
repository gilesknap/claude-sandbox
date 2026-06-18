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
  paths (e.g. network-identity disclosure, which applies in the
  `CLAUDE_SANDBOX_EGRESS_JAIL=0` open-egress mode) — these are on the
  radar by design, not failures.

> **Jailed sessions.** When the egress jail is on (the default), the full
> 18-check battery still passes: check 06 asserts the *effective*
> capability set (`CapEff=0`), which bwrap's `--cap-drop ALL` empties even
> inside the jail's nested user namespace. The `CapBnd` *ceiling* will
> read full (`…1ffffffffff`) rather than `0` — a nested-userns artifact,
> not a regression; effective caps are zero and the netns routes are owned
> by an ancestor namespace. A jail-aware additional check (netns exists +
> RFC1918 blackhole holds) is a planned future addition, not yet
> implemented. See {ref}`adr-network-egress-jail`.

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
