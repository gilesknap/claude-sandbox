# Enforce sandbox use across an organisation

Make Claude Code on a *host* machine refuse to run and redirect the user
to claude-sandbox, so the default path for everyone is the isolated
devcontainer rather than an unwrapped session against host credentials.

This is for IT / platform teams rolling the sandbox out as policy. It is
deliberately a *light* control: it defaults everyone into the sandbox and
makes running unwrapped a visible, deliberate act — it is not an
unbypassable security boundary (see [Limits](#limits) below).

## How it works

Claude Code reads settings from several tiers. **Managed settings is the
highest-precedence tier — a user cannot override or delete it by editing
their own `~/.claude/settings.json`.** That is the property that makes
this enforcement real rather than advisory, and it is the same tier the
sandbox's own [integrity guard](../explanations/integrity-guard.md) uses.

The lever is a `UserPromptSubmit` hook — the one hook type that can
actually *stop* work (`exit 2` blocks the prompt and surfaces stderr).
A `SessionStart` hook can only warn. You ship a tiny gate script that
exits non-zero with a redirect message, wired in via a managed-settings
policy file deployed to every workstation by your MDM (Jamf, Intune,
Ansible, …).

A corporate `/etc` policy lives only on the host filesystem. The sandbox
devcontainer has its own `/etc` and never sees it, so this gate fires
*only* on unwrapped host sessions — there is no need to test for "am I in
the sandbox?". It blocks unconditionally.

## 1. The gate script

Deploy root-owned, off the user's `PATH`, e.g.
`/usr/libexec/claude-sandbox/corp-gate.sh` (`0755`):

```bash
#!/usr/bin/env bash
set -uo pipefail
[ -t 0 ] || cat >/dev/null 2>&1 || true   # drain the stdin JSON

# Escape hatch — intentionally NOT named in the block message below, so a
# naive user can't trivially avoid the policy. Document it only in an
# internal runbook that makes the user acknowledge they are giving up
# credential isolation.
[ "${CLAUDE_SANDBOX_ALLOW_UNWRAPPED:-}" = "1" ] && exit 0

echo "BLOCKED by IT policy: Claude Code must be run inside claude-sandbox so host
credentials stay isolated. Set it up: https://github.com/gilesknap/claude-sandbox
(clone + ./install, then launch claude inside the devcontainer)." >&2
exit 2
```

## 2. The managed-settings policy

Write this to the OS-specific managed-settings path (root-owned, `0644`):

| OS      | Path                                                        |
|---------|-------------------------------------------------------------|
| macOS   | `/Library/Application Support/ClaudeCode/managed-settings.json` |
| Linux   | `/etc/claude-code/managed-settings.json`                    |
| Windows | `C:\ProgramData\ClaudeCode\managed-settings.json`           |

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "bash /usr/libexec/claude-sandbox/corp-gate.sh" }] }
    ]
  }
}
```

Do **not** set `allowManagedHooksOnly` — it would also suppress users'
own legitimate hooks. Plain managed hooks fire *in addition to*
user/project hooks, which is what you want.

## Knobs

- **Hard enforcement.** Drop the `CLAUDE_SANDBOX_ALLOW_UNWRAPPED` line
  from the gate to remove the bypass entirely.
- **Claude Code on the web.** Add `[ "${CLAUDE_CODE_REMOTE:-}" = "true" ]
  && exit 0` as the first check if your org uses Claude Code on the web
  and wants it allowed (those sessions are already sandboxed by
  Anthropic).

## Limits

This is a *nudge*, not a hard control. It defaults everyone into the
sandbox and turns bypass into a deliberate act, which is the realistic
goal of an org rollout. It does not — and cannot — stop a determined
developer who installs their own `claude` binary outside the managed
path. Do not present it to a security team as an unbypassable boundary;
the actual credential isolation is provided by the bwrap shadow, which
this policy merely steers people toward.

## See also

- [The integrity guard](../explanations/integrity-guard.md) — the
  in-sandbox counterpart, which blocks prompts when Claude is launched
  unwrapped *inside* a configured host.
- [Promote to a workspace](promote-to-a-workspace.md) — make an
  individual repo a self-sufficient sandbox host.
