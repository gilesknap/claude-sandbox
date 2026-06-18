# Threat model

`claude-sandbox` exists to answer one question: *what can go wrong when a
developer runs Claude Code inside a devcontainer, and which of those failures
is this tool responsible for preventing?* This page explains the reasoning
behind the boundary. For the hard, look-it-up tables — the exact defences and
the exact exposures — see [locked-down defences](../reference/locked-down-defences.md)
and [deliberately exposed](../reference/deliberately-exposed.md). For how the
bwrap primitives fit together to enforce all this, see
[architecture](architecture.md).

## Who and what we defend against

The adversary is not the developer. It is an **LLM-driven attack** riding on
input the developer did not write: a hostile prompt, a hostile file Claude is
asked to read, or a hostile tool result. Any of these can attempt to steer
Claude's tools toward four goals:

- **Credential exfiltration** — reading host secrets (env vars, dotfiles,
  token stores, IPC sockets) and shipping them out.
- **Driving the host IDE** — reaching across the IPC bridges and runtime
  sockets that connect the devcontainer to the editor and the host desktop.
- **Privilege escalation inside the devcontainer** — setuid tricks, capability
  abuse, ptrace/kill against neighbouring processes, terminal injection.
- **Lateral network movement** — using the host's network reach to pivot to
  internal RFC1918 hosts, the `169.254.169.254` metadata endpoint, or lab devices
  reachable by bare IP with default credentials (EPICS IOCs, PMAC motion
  controllers — where a hostile session reaching a PMAC is a *safety* incident,
  not just an information one). This is the threat the default
  [egress jail](#the-egress-jail-and-the-native-sandbox) closes.

Each defence in the [locked-down table](../reference/locked-down-defences.md)
maps one-to-one onto an *observed* path for one of those goals and the bwrap
primitive that closes it. The design does not chase hypothetical attacks; it
closes the concrete exfiltration routes — environment variables, dotfiles, IPC
and runtime sockets, X11, `TIOCSTI` terminal injection, setuid escalation —
that an attacker-controlled Claude can actually reach.

A consequence of taking the *developer* off the threat list: enforcement
targets *accidental* exposure, not a determined human deliberately dismantling
their own sandbox. The integrity guard is built to survive Claude Code's own
self-updates and stray `~/.claude/settings.json` edits, not to win a fight
against the box's owner with root.

## Why each exposure is in or out of scope

The split between in-scope and out-of-scope is not arbitrary; it follows from
what this tool *is*: a **credential-isolation tool**, not a general sandbox
against arbitrary native code.

A defence is **in scope** when it closes a credential or host-control path that
the sandbox can plug without breaking Claude's job. Those are exactly the rows
of the lockdown table — env scrubbing, the strict-under-`/root` inversion,
dropped capabilities, the PID/IPC/UTS namespaces, the masked IPC and runtime
dirs. They cost nothing Claude needs.

A defence is **out of scope** when plugging it would either break Claude or
exceed what a credential-isolation tool can honestly promise. The
[out-of-scope table](../reference/deliberately-exposed.md) records each, but the
rationale matters:

- **Workspace contents** are out of scope because Claude *has to* read your
  workspace to be useful. This is the one irreducible exposure — see the
  [caveat](#the-irreducible-workspace-visibility-caveat) below.
- **The container host kernel** is out of scope because a bwrap-aware kernel
  exploit is a different class of problem. This tool isolates credentials; it
  does not claim to contain arbitrary native code. The devcontainer host is the
  trust boundary, and keeping the kernel patched is the operator's job.
- **Lateral network movement to internal hosts** is now *in scope* and addressed
  by default: the egress jail ({ref}`adr-network-egress-jail`, on by default)
  runs Claude in a per-process network namespace that blackholes RFC1918, so a
  compromised session cannot pivot to internal LANs or lab devices. What remains
  *out of scope* is **internet-domain / exfil filtering** — restricting *which*
  outbound domains Claude reaches, or stopping a session POSTing data to a
  permitted destination. A hostname allowlist is Claude Code's native sandbox's
  job (`allowedDomains`); a DLP boundary belongs at the devcontainer edge. See
  [the egress jail and the native sandbox](#the-egress-jail-and-the-native-sandbox)
  below.
- **Non-standard credential paths** are out of scope as a guarantee because the
  installer can warn about odd mounts it sees at install time but cannot
  enumerate every custom bind. Auditing your devcontainer's `mounts` block is
  yours.

The throughline: the sandbox promises **credential isolation** and **lateral
network isolation** against an LLM-driven attacker. Where a promise would still
be dishonest — kernel exploits, internet-domain / exfil control, mounts the
installer never saw — it is named as out of scope rather than implied.

## What is deliberately exposed, and why

A handful of paths are reachable from inside Claude *on purpose*, because
locking them down would defeat the tool. The full list with modes lives in
[deliberately exposed](../reference/deliberately-exposed.md); the rationale is
consistent across them:

- The **workspace** is read-write because editing your project is the entire
  point.
- The **token stores** (`gh`, `glab-cli`) are bound read-write so Claude can
  push code — the single largest deliberate exposure, addressed under
  [PAT hygiene](#pat-hygiene-the-soft-underbelly).
- **Claude's own state** (`~/.claude`, `~/.claude.json`, caches) is bound so
  settings, skills, and the OAuth token survive across launches instead of
  being swallowed by the strict-under-`/root` tmpfs.
- The **curated gitconfig** and the host **system gitconfig** are exposed
  read-only, the latter neutralised for `git` itself via
  `GIT_CONFIG_SYSTEM=/dev/null`.
- **Internet egress** (`api.anthropic.com`, the forges, package registries) is
  reachable because Claude needs it — but only the internet, DNS, and explicitly
  `allow-ip`-listed devices: the egress jail
  ([below](#the-egress-jail-and-the-native-sandbox)) blackholes the internal
  RFC1918 network by default, so this exposure does not extend to lateral
  movement onto internal hosts.

The governing principle is *minimum necessary exposure with a forward-compatible
default*: `~/.config/` keeps a strict two-entry allowlist because credentials
live there by XDG contract, so a new credentialed tool is masked for free;
`~/.local/share/` and `~/.cache/` are bulk-bound because they hold plugin trees
and caches, not secrets. That trade-off and its failure mode (a tool that
mis-files credentials under `~/.local/share/`) are detailed in
[deliberately exposed](../reference/deliberately-exposed.md).

## The irreducible workspace-visibility caveat

This is the limitation worth stating plainly, because no amount of bwrap fixes
it: **workspace contents are visible to Claude, and that is by design.** The
sandbox protects you against host-credential leaks through env vars, dotfiles,
and IPC sockets. It does *not*, and cannot, hide what you have checked out into
the workspace — Claude has to read it to do its job, so anything in the
workspace is reachable from Claude's tools.

The practical consequence is a rule, not a feature:

> Keep secrets outside the workspace.

Mount them via your devcontainer's `mounts` (for example into `~/.config/`, which
sits behind the strict allowlist) rather than dropping a `.env` file full of
production credentials at the workspace root and expecting it to be invisible.
It will not be. The sandbox draws the credential boundary at the workspace
edge; what you place inside that edge, you are choosing to expose.

## PAT hygiene: the soft underbelly

The deliberate read-write bind of the `gh` and `glab` token stores is the
sandbox's softest point, and it is worth being explicit about why. Everything
else the lockdown closes — env vars, dotfiles, sockets — is *taken away* from
Claude. The forge tokens are *handed to* Claude, because pushing code requires
them. A compromised session can therefore use those tokens to push to any
repository the PAT covers, modify CI workflows, or reach other repos in the
same organisation. No bwrap primitive can distinguish a legitimate `git push`
from a malicious one; they use the same token.

Because the sandbox cannot shrink that blast radius, the *token* must. The
mitigation is scope discipline at the source, and the reasoning is
blast-radius arithmetic:

- A **fine-grained, single-repo token** means a compromise reaches exactly the
  repo you are working on — not the org.
- A **short expiry** (7–30 days) means a leaked token dies on its own; re-auth
  costs seconds.
- **Omitting `workflow` scope** (unless Claude must edit GitHub Actions) keeps a
  compromise away from your CI; **no `admin:*` or org-wide write** keeps it off
  everything else.
- GitLab gets the equivalent: project-scoped tokens, `api` only if you need
  push, otherwise `read_repository` + `write_repository`.

The `just gh-auth` / `just glab-auth` helpers keep the token out of shell
history, but they do **not** enforce scope — that part is irreducibly yours.

When a session genuinely does not need to push, the right move is to remove the
exposure entirely rather than rely on a tight token: `CLAUDE_SANDBOX_NO_FORGE=1`
in `remoteEnv` skips the `gh`/`glab` binds and strips the credential helpers
from the generated gitconfig, so `git push` fails by design. The exact
mechanism and how to set it are in
[deliberately exposed](../reference/deliberately-exposed.md).

## The egress jail and the native sandbox

Credential isolation answers *what can a compromised session read?* The egress
jail answers a second question — *what can it reach?* — and as of 2026-06-18 it
is on by default. The threat is **lateral movement, not exfiltration**: bwrap
already hides the credentials, so the asset worth protecting is *network reach*.
Without the jail, a prompt-injected session that shares the host network
namespace can probe RFC1918, hit `169.254.169.254`, and — the incident that
motivates this — reach lab devices with default credentials (EPICS IOCs, PMAC). Reaching a PMAC is a
*safety* incident, not merely an information one.

The jail ({ref}`adr-network-egress-jail`) runs *only* Claude in a per-process
network namespace beneath bwrap. A routing allowlist blackholes `10/8`,
`172.16/12`, `192.168/16`, the connected subnet, and link-local `169.254/16`,
leaving the internet, DNS, and the device IPs you list as `allow-ip` reachable —
so Claude still works while a compromised session has nowhere internal to pivot.
It is **fail-closed**: if `/dev/net/tun`, pasta, or `unshare` is unavailable,
`claude` refuses to launch rather than silently fall back to open egress. The
escape hatch `CLAUDE_SANDBOX_EGRESS_JAIL=0` (env, or `egress-jail = 0` in
`/etc/claude-sandbox.conf`) restores the older shared-host-netns world of
{ref}`adr-network-egress-open`. Normal, non-Claude shells keep host networking
untouched. The operational recipe — adding the required `--device=/dev/net/tun`,
allow-listing a device, or turning the jail off — is in
[Configure the network egress jail](../how-to/network-egress-jail.md); the config
keys are in [configuration](../reference/configuration.md).

### Meshing with Claude Code's native sandbox

This tool is not an alternative to Claude Code's own sandbox — they are
composable layers covering different surfaces, and the strongest posture runs
both.

- **`claude-sandbox` (this repo)** provides two things: **credential protection**
  (the bwrap bind model — env scrubbing, the strict-under-`$HOME` inversion,
  masked IPC/runtime sockets) and **sideways / lateral network isolation** (the
  egress jail blackholes RFC1918 so a compromised session cannot pivot to
  internal hosts or lab devices). It does *not* restrict *which* internet domains
  Claude reaches.
- **Claude Code's native sandbox** provides the complementary surface —
  **internet domain isolation** (an `allowedDomains` allowlist enforced by an SNI
  proxy), restricting outbound HTTPS to named hosts. It does *not* express
  bare-IP / UDP / dynamic-port lab-device traffic, and it does not provide this
  repo's credential-bind model.

The two mesh: credential isolation + lateral isolation (this tool) + internet
domain allowlisting (native) is defence in depth across complementary surfaces —
three layers, not three alternatives. The cohort framing in
{ref}`adr-network-egress-jail` makes the division concrete. **Cohort A** needs
HTTPS to *named* hosts; Claude Code's native `allowedDomains` fits it (the
dual-sandbox work is issue #33, still open). **Cohort B — this repo's users** —
reach lab devices by **bare RFC1918 IP, over UDP, on dynamic ports** (EPICS
Channel Access / pvAccess, PMAC); a hostname allowlist *cannot* express that,
which is exactly why this tool's IP/CIDR egress jail exists.
