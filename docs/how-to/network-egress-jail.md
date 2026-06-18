# Configure the network egress jail

The egress jail runs Claude in its own network namespace and blackholes
RFC1918 (`10/8`, `172.16/12`, `192.168/16`) and link-local (`169.254/16`) so a
compromised or prompt-injected session **cannot pivot to internal hosts or lab
devices** (EPICS IOCs, PMAC). The internet, DNS, and any IPs you allow stay
reachable. It is **on by default** ({ref}`adr-network-egress-jail`) and
**fail-closed**. Normal, non-Claude shells keep host networking untouched.

For the design rationale and how it meshes with Claude Code's native sandbox,
see [the egress jail and the native sandbox](../explanations/threat-model.md#the-egress-jail-and-the-native-sandbox).

```{include} ../_snippets/clone-note.md
```

## Add the one required container device

The jail needs `/dev/net/tun` in the container. An installer cannot add a
container runArg, so you must add it to your devcontainer yourself:

```json
// .devcontainer/devcontainer.json → runArgs
"runArgs": ["--device=/dev/net/tun"]
```

Rebuild the devcontainer for it to take effect. `install.sh` already installs
`passt` (which provides `pasta`), so that dependency is never the blocker.

**Fail-closed:** if `/dev/net/tun`, `pasta`, or `unshare` is missing while the
jail is on, `claude` **refuses to launch** rather than silently falling back to
open egress. The error names both the fix and the escape hatch.

## Keep a lab device or internal forge reachable

Device IPs you still need (an EPICS IOC, a PMAC, your internal GitLab) must be
punched through the blackhole with `allow-ip` in the host-global config. Edit the
clone conf at `.devcontainer/claude-sandbox.conf`:

```ini
# .devcontainer/claude-sandbox.conf  (installed to /etc/claude-sandbox.conf)
allow-ip = 172.23.142.119   # internal GitLab forge
allow-ip = 172.23.1.3       # an EPICS IOC / PMAC
```

One bare IP per line; repeat for multiple devices. The shipped default allows
Diamond's internal GitLab (`172.23.142.119`) so `git push` to the forge keeps
working. `allow-ip` lives in `/etc`, **not** the workspace, so a compromised
session cannot widen its own reach.

Apply it the same way as any conf change: re-run `./install`, or rebuild the
devcontainer (postCreate re-stamps the conf).

## Disable the jail

Two ways; env wins over conf:

- **Per host** — uncomment `egress-jail = 0` in
  `.devcontainer/claude-sandbox.conf`, then re-run `./install` (or rebuild).
- **Per session** — `CLAUDE_SANDBOX_EGRESS_JAIL=0 claude`, or set it in your
  devcontainer's `remoteEnv`.

Disabling restores the open-egress world of {ref}`adr-network-egress-open`:
Claude shares the host network namespace, with no per-process firewall.

## A note on Channel Access for Claude

Claude's private netns has no LAN broadcast domain, so EPICS Channel Access
**auto-discovery does not work for Claude** while jailed — use a unicast
`EPICS_CA_ADDR_LIST`. Normal (non-Claude) shells keep host networking and
broadcast.

## See also

- [Threat model](../explanations/threat-model.md) — why lateral movement is the
  risk this jail addresses, and how it meshes with the native sandbox.
- [Configuration](../reference/configuration.md) — the `egress-jail` / `allow-ip`
  conf keys and the `CLAUDE_SANDBOX_EGRESS_JAIL` environment variable.
- {ref}`adr-network-egress-jail` — the full design (Design D).
