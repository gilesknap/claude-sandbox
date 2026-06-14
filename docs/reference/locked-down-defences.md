# Locked-down defences

The canonical map of every defence the sandbox enforces, the `bwrap`
primitive that delivers it, and the [`/verify-sandbox`](verification-checks.md)
check number that proves it. Each row corresponds to one observed
exfiltration path closed by the matching primitive.

## Defence → primitive → check

| Defence | bwrap primitive | Verify |
|---|---|---|
| Sandbox is actually entered | `IS_SANDBOX=1` sentinel | check 01 |
| Setuid escalation blocked | `NO_NEW_PRIVS` (set by bwrap before exec) | check 02 |
| Strict-under-`/root` by inversion | `--tmpfs /root` then re-bind `.claude` / `.claude.json` / `.cache` / `.config/{gh,glab-cli}` / `.local/share` (with `applications/` + `claude/` tmpfs-masked) | check 03 |
| Host env vars scrubbed | `--clearenv` + explicit allow-list | checks 04, 05 |
| Zero capabilities | `--cap-drop ALL` | check 06 |
| PID namespace (kill/ptrace scoping) | `--unshare-pid` | check 07 |
| SysV IPC namespace | `--unshare-ipc` | check 08 |
| UTS namespace | `--unshare-uts` | check 09 |
| TIOCSTI terminal injection blocked | `--dev /dev` + `script(1)` pty wrap | check 10 |
| VS Code IPC bridges masked | `--tmpfs /tmp` | check 11 |
| User runtime dir masked | `--tmpfs /run/user` | check 12 |
| Docker/Compose secrets masked | `--tmpfs /run/secrets` | check 13 |
| `.netrc` defence in depth | `--bind-try /dev/null /root/.netrc` | check 14 |
| `.Xauthority` defence in depth | `--bind-try /dev/null /root/.Xauthority` | check 15 |
| Curated gitconfig in effect | `GIT_CONFIG_GLOBAL=/etc/claude-gitconfig`, `GIT_CONFIG_SYSTEM=/dev/null` | check 16 |
| Chrome browser-extension RPC channel disabled | shadow injects `--no-chrome` and strips user `--chrome` so Claude Code never writes its `NativeMessagingHosts` manifest | check 03 (regression manifests as browser dirs under `~/.config`) |

## Notes

### Network egress is open

Network egress (`--share-net`, NOT unshared) is deliberately open so
Claude can reach `api.anthropic.com`. There is no PASS/FAIL check for
it — any regression makes Claude fail on first use rather than
silently. The shared netns is also why the host's network identity is
disclosable from inside; see the
[threat model](../explanations/threat-model.md).

### `--die-with-parent`

Implicit: `--die-with-parent` — the sandbox disappears the moment
Claude does.

### Refusal-on-failure

If the host cannot run unprivileged user namespaces, the installer
refuses with a specific actionable diagnostic. Silent degradation to
"Claude installed but not sandboxed" is itself a UX failure mode, so it
is not allowed to happen.
