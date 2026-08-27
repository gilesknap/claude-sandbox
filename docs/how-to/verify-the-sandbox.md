# Verify the sandbox

Confirm that the Claude process you are running is actually inside the
bwrap isolation, and that no defence has regressed.

```{include} ../_snippets/clone-note.md
```

## Run the verification

From a terminal, in any workspace, *outside* a Claude session:

```bash
claude-sandbox verify
```

That launches a sandboxed session, runs the checks against the live
process, and prints a summary table.

Inside a claude-sandbox clone it runs the full two-phase audit; anywhere
else it runs the phase-1 battery. To drive the full audit yourself from
within a Claude session in a clone:

```bash
/verify-sandbox
```

## What it does

There are two phases:

1. **The PASS/FAIL battery** — 20 checks against the running process,
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
  paths (e.g. network-identity disclosure, which applies only when an
  operator has disabled the egress jail) — these are on the radar by
  design, not failures.

> **Jailed sessions.** When the egress jail is on (the default), the full
> 20-check battery still passes: check 06 asserts the *effective*
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
  blocks prompts when Claude is unwrapped, so you do not have to verify
  by hand to stay protected.
