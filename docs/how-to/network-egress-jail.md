# Configure the network egress jail

The egress jail runs Claude in its own **IPv4-only** network namespace and
blackholes RFC1918 (`10/8`, `172.16/12`, `192.168/16`), CGNAT (`100.64/10`,
Tailscale et al.), every connected subnet, and link-local (`169.254/16`) so a
compromised or prompt-injected session **cannot pivot to internal hosts or lab
devices** (EPICS IOCs, PMAC) — over IPv4 or IPv6. The internet, DNS, and any IPs
you allow stay reachable. It is **on by default** ({ref}`adr-network-egress-jail`)
and **fail-closed**. Normal, non-Claude shells keep host networking untouched.

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

**Rootful docker cannot host the jail.** If the refusal is `pasta failed to
attach to the netns` and the pasta log shows `Couldn't open user namespace
/proc/<pid>/ns/user: Permission denied`, the container is running under
*rootful* docker, whose namespace-access semantics deny pasta the attach —
lifting seccomp/AppArmor confinement does not help. Run the container under
rootless podman (the supported runtime), or accept the weaker posture of
disabling the jail for that host (see below).

## Keep a lab device or internal forge reachable

Device IPs you still need (an EPICS IOC, a PMAC, your internal GitLab) must be
punched through the blackhole with `allow-ip` in the sandbox config. Edit
`/etc/claude-sandbox.conf` in the container (you are root):

```ini
# /etc/claude-sandbox.conf
allow-ip = 172.23.142.119   # internal GitLab forge
allow-ip = 172.23.1.3       # an EPICS IOC / PMAC
```

One bare IP per line; repeat for multiple devices. The shipped default allows
Diamond's internal GitLab (`172.23.142.119`) so `git push` to the forge keeps
working. `allow-ip` lives in `/etc`, **not** the workspace, so a compromised
session cannot widen its own reach.

The next `claude` launch picks the change up. Edits are per-devcontainer
and not persisted — a rebuild, re-install, or `claude-sandbox update`
restores the shipped defaults, so re-apply afterwards (teams bake a
persistent conf in at install time — see
[Sandbox a team devcontainer](sandbox-a-team-devcontainer.md)).

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
