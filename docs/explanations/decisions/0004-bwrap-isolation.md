(adr-bwrap-isolation)=

# 4. Isolate with bwrap: drop all capabilities, scrub the environment, invert /root to default-deny

Date: 2026-05-11

## Status

Accepted

## Context

We need process isolation that a rootless-podman devcontainer can run
unprivileged, with no `CAP_SYS_ADMIN` and a strict seccomp profile. The embedded
predecessor used `unshare -m` plus tmpfs overlays (see
{ref}`adr-standalone-repo`); we wanted something stronger and declarative — an
argv you can read top-to-bottom rather than a sequence of imperative mount
steps.

## Decision

Build the isolation as a single `bwrap` argv: `--cap-drop ALL`, `--clearenv`
plus an explicit environment allow-list, `--unshare-{pid,ipc,uts}`,
`NO_NEW_PRIVS`, and — the load-bearing move — **invert `/root` to default-deny**:
`--tmpfs /root`, then re-bind back only an allow-list of paths (`.claude`,
`.claude.json`, `.cache`, `.config/{gh,glab-cli}`, `.local/share`). Home is
default-deny; you opt paths *in*, you never blacklist them out. Credential
isolation is therefore *decided* in this allow-list (`bwrap_argv_build`), not in
any advisory check (see {ref}`adr-integrity-surfaces`).

## Consequences

- A new credentialed tool that drops files under `$HOME` or
  `$HOME/.config/<tool>/` is masked **for free** — the forward-compatible
  default is "hidden."
- Every primitive is provable: `/verify-sandbox`'s 18-check battery maps each
  row of `README-CLAUDE.md`'s defence table to the bwrap primitive that enforces
  it.
- The argv builder is kept inline and pure so `tests/bwrap_argv.sh` can assert
  over the built argv directly. Which categories under `$HOME` flip polarity is
  refined in {ref}`adr-xdg-split`; where the *config* that drives these binds is
  read from is fixed by {ref}`adr-untrusted-workspace`.
