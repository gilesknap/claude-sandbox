# diagnostic scripts

Operator-only validation tools for the network egress jail (ADR 0015 /
issue #56). **Not part of the audited product surface**: nothing in
`install.sh`, `promote.sh`, the `justfile`, or CI references these — they are
not installed on a host, not copied by `just promote`, and not run by the
test suite. They exist as live proof-of-concept evidence for ADR 0015 and as
troubleshooting aids when the jail won't come up on a new host.

**Run them UNJAILED** — from a normal terminal, not from inside a sandboxed
`claude`. Each needs `unshare` (util-linux); the pasta-based ones also need
`pasta` (`apt-get install passt`) and `--device=/dev/net/tun` on the
container.

| Script | What it proves |
|---|---|
| `probe-network-layers.sh` | Splits the failure modes: the tun-**independent** core (unprivileged netns + in-netns routing) vs. the tun-**dependent** pasta forwarder. Start here to localise a setup failure. |
| `probe-network-jail.sh` | Full surgical-routing policy end-to-end: RFC1918 + connected subnet blackholed; gateway, DNS, and allow-ip devices reachable; routes immutable from inside the jail. |
| `probe-network-jail-caps.sh` | Cap-ceiling diligence: confirms the full `CapBnd` (present because the jail nests a userns) cannot be re-raised to weaken the read-only mounts. |

These complement — they do not replace — the in-sandbox integrity battery
(`/verify-sandbox`, `sandbox-verify.sh`), which runs *inside* the jail.
