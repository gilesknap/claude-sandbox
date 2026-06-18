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
| Lateral-movement (RFC1918) egress isolation | netns + `pasta` routing allowlist around bwrap (NOT a bwrap primitive — {ref}`ADR 0015 <adr-network-egress-jail>`); blackholes 10/8, 172.16/12, 192.168/16, 169.254/16 | no jail-aware check needed — check 06 (`CapEff=0`) still passes in the nested userns; an optional netns/blackhole check is a future item |

## Notes

### Network egress is jailed by default

As of 2026-06-18 the egress jail ({ref}`adr-network-egress-jail`) is the
default posture: Claude runs in its own per-process network namespace,
bridged to the internet by `pasta`, with a routing allowlist that
blackholes RFC1918 (`10/8`, `172.16/12`, `192.168/16`, the connected
subnet) and link-local (`169.254/16`) so a compromised session cannot
pivot to internal hosts or lab devices. `api.anthropic.com`,
GitHub/GitLab, DNS resolvers, and any configured `allow-ip` devices stay
reachable so Claude still works.

It is **fail-closed** — if `/dev/net/tun`, `pasta`, or `unshare` is
missing, `claude` refuses to launch rather than silently dropping back to
open egress. The escape hatch is `CLAUDE_SANDBOX_EGRESS_JAIL=0` (env, per
session, or `egress-jail = 0` in `/etc/claude-sandbox.conf`; env wins),
which restores the older shared-host-netns world (`--share-net`, NOT
unshared; {ref}`adr-network-egress-open`). Only that `=0` path shares the
host netns, which is what makes the host's network identity disclosable
from inside.

The jail sits *around* bwrap, so [`/verify-sandbox`](verification-checks.md)
passes unchanged inside it — check 06 asserts `CapEff=0` (the effective
set, empty even in the jail's nested userns), not netns state. There is
therefore no PASS/FAIL check for the jail itself (a netns/blackhole check
is a future item); any egress regression makes Claude fail on first use
rather than silently. See the
[threat model](../explanations/threat-model.md).

### `--die-with-parent`

Implicit: `--die-with-parent` — the sandbox disappears the moment
Claude does.

### Refusal-on-failure

If the host cannot run unprivileged user namespaces, the installer
refuses with a specific actionable diagnostic. Silent degradation to
"Claude installed but not sandboxed" is itself a UX failure mode, so it
is not allowed to happen.
