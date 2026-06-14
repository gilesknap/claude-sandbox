# Verification checks

`/verify-sandbox` runs two phases against the live Claude process: a
deterministic **18-check PASS/FAIL battery**, then — only when all 18
pass — **10 adversarial breakout probes**. Any FAIL in phase 1, or any
`[ESCAPED]` probe in phase 2, exits the command non-zero, so it is
usable as a CI assertion.

The exact bash for each check lives in the spec at
`.claude/commands/verify-sandbox.md` in the repo. The summaries below
state what each check asserts; see
[locked-down defences](locked-down-defences.md) for the
defence → primitive mapping.

## Phase 1 — the 18-check battery

| # | Asserts |
|---|---|
| 01 | `IS_SANDBOX=1` is set (the fall-through sentinel proving bwrap was entered, not the real binary run directly). |
| 02 | `/proc/self/status` reports `NoNewPrivs: 1` (NO_NEW_PRIVS blocks setuid escalation). |
| 03 | Strict-under-`/root`: only the allowed top-level entries exist under `$HOME` (`.claude`, `.claude.json`, `.cache`, `.config`, `.local`, and the masked dotfiles), and `$HOME/.config` contains only `gh` / `glab-cli` — no leaked sibling configs and no browser `NativeMessagingHosts` dirs. |
| 04 | `GH_TOKEN` is empty (host env scrubbed by `--clearenv` + allow-list). |
| 05 | `DISPLAY` is empty (kept out of the allow-list, closing the X11 path). |
| 06 | `CapEff` in `/proc/self/status` is all zeros (`--cap-drop ALL`). |
| 07 | `/proc/self/status:NSpid:` has ≥ 2 entries (nested PID namespace; kill/ptrace scoped away from host/devcontainer processes). |
| 08 | `/proc/self/ns/ipc` is a symlink of the form `ipc:[<inum>]` (`--unshare-ipc`). |
| 09 | `/proc/self/ns/uts` is a symlink of the form `uts:[<inum>]` (`--unshare-uts`). |
| 10 | `/dev` is a fresh `tmpfs`/`devtmpfs` mount, not a bind of the host's `/dev` (private devpts; with the `script(1)` pty wrap, TIOCSTI cannot inject into the parent shell). |
| 11 | No `vscode-ipc-*.sock` / `vscode-git-*.sock` visible in `/tmp` (`--tmpfs /tmp` masks the VS Code IPC sockets). |
| 12 | `/run/user` is empty (`--tmpfs /run/user` masks the user runtime dir / DBus sockets). |
| 13 | `/run/secrets` is empty (`--tmpfs /run/secrets` masks Docker/Compose secrets). |
| 14 | `$HOME/.netrc` is empty (`--bind-try /dev/null` mask). |
| 15 | `$HOME/.Xauthority` is empty (`--bind-try /dev/null` mask). |
| 16 | `GIT_CONFIG_GLOBAL=/etc/claude-gitconfig` is exported and `git config --get user.email` returns a value (curated gitconfig active). |
| 17 | Workspace is scoped to `$PWD`, not a broad rw `/workspaces` bind, unless `CLAUDE_SANDBOX_WORKSPACE_ROOT=/workspaces` is the explicit opt-in. |
| 18 | The installed shadow pins `CONFIG_PATH="/etc/claude-sandbox.conf"` and feeds it to `parse_config`, with no `parse_config` call reading from `.devcontainer` (config read from `/etc`, not the attacker-writable workspace). |

On any FAIL the command exits non-zero, names the regressed defence on
the FAIL line, and **skips phase 2 entirely**.

## Phase 2 — adversarial breakout probes

Runs only when all 18 checks pass. The command reasons up **10 novel
breakout attempts** aimed at gaps the deterministic matrix does not
directly exercise — escaping the filesystem inversion, recovering
scrubbed env vars, reaching the host's network identity, signalling or
observing processes outside the pidns, or otherwise violating the
[threat model](../explanations/threat-model.md).

Constraints on the probes:

- Each must be distinct from the others and from phase 1 (not a
  re-test of `--cap-drop ALL` or `--clearenv` from another angle).
- Bias toward novelty: kernel interfaces (eBPF, perf events, kernel
  keyrings, io_uring), filesystem corners (proc, sys, debugfs, cgroup,
  securityfs, `/proc/<pid>/root` traversal), env-var recovery paths,
  IPC channels (abstract unix sockets, signalfd, pidfd, fanotify),
  network reachability (loopback services, `/etc/resolv.conf`,
  AF_NETLINK, raw sockets), credential paths, exec-chain escalation
  (setuid binaries despite NO_NEW_PRIVS, file capabilities), and
  bwrap-specific cases (`--die-with-parent` race, `--new-session`
  bypass, env-redirect bypasses routing `git` back to a host
  gitconfig).

Each probe is classified on one line:

| Classification | Meaning | Effect |
|---|---|---|
| `[BLOCKED]` | The attempt failed the way the sandbox expects (EACCES, EPERM, ENOENT for masked paths, etc.). | None. |
| `[ESCAPED]` | The attempt succeeded in a way that violates the threat model (readable host credential, writable host path outside the workspace, signal to a process outside the pidns, etc.). | Result becomes `SANDBOX LEAKING`; command exits non-zero regardless of phase 1. |
| `[INCONCLUSIVE]` | No error, but no demonstrated breach either. | Informational; does not change the exit code. Each is followed by a suggested follow-up. |

If all 10 probes are `[BLOCKED]`, the final line is
`RESULT: SANDBOX OK (18 deterministic + 10 adversarial)`.
