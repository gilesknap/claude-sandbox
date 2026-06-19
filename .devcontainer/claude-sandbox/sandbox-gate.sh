#!/usr/bin/env bash
# UserPromptSubmit hook (user-scope, GLOBAL). Fail-closed gate: blocks
# every prompt unless the claude-sandbox bwrap shadow is in effect
# (IS_SANDBOX=1, set only by the bwrap launcher).
#
# This is the ONE mechanism that can actually STOP work when Claude is
# running unwrapped — SessionStart hooks can only warn. It is lean by
# design: the deep integrity battery lives in the SessionStart verifier
# (sandbox-verify.sh), which runs once per session. Here we do a single
# string compare so the per-prompt cost is ~zero.
#
# Installed at an ABSOLUTE path under /usr/libexec (root-owned, off-PATH,
# ro inside the sandbox) so it resolves from any cwd and cannot be
# rewritten from inside the jail.
#
# Escape hatch: the OPERATOR creates the ROOT-OWNED flag file
# /etc/claude-code/allow-unwrapped to downgrade to warn-only (the
# SessionStart hook still warns loudly). This is deliberately a flag
# under /etc — NOT an environment variable — because a confined Claude
# can write ~/.claude/settings.json (host-shared, persistent), and
# Claude Code exports that file's "env" block into later sessions. An
# env-var hatch (CLAUDE_SANDBOX_ALLOW_UNWRAPPED) was therefore forgeable
# from inside the jail and would silently, persistently neutralise the
# gate on a later UNWRAPPED launch (deep-review H4, issue #63). /etc is
# ro inside the bwrap shadow (`--ro-bind / /`) and not host-shared, so
# only root on the host (or a deliberate ./install) can create the flag
# — the same /etc-not-the-rw-workspace discipline as ADR 0012/0013.
#
# Skips on Claude Code Web (CLAUDE_CODE_REMOTE=true) — already sandboxed
# by Anthropic.
set -uo pipefail

# Root-owned escape-hatch flag. HARD-CODED, never read from the environment:
# the whole point of the H4 fix is that a confined Claude can forge the gate's
# environment via ~/.claude/settings.json's "env" block, so ANY env-driven flag
# path (or env hatch) is bypassable. Tests exercise the decision through
# gate_allows() with the path passed as an ARGUMENT (see the source guard
# below), not via a forgeable variable.
ALLOW_UNWRAPPED_FLAG="/etc/claude-code/allow-unwrapped"

# gate_allows FLAG: succeed (return 0) when the prompt should be let through —
# running on Claude Code Web, inside the bwrap shadow, or the operator's
# root-owned escape-hatch flag is present. FLAG is a parameter so the test seam
# is an argument, not an environment variable a confined Claude could forge.
gate_allows() {
    local flag="$1"
    [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && return 0
    [ "${IS_SANDBOX:-}" = "1" ]            && return 0
    [ -f "$flag" ]                         && return 0
    return 1
}

gate_main() {
    # UserPromptSubmit delivers JSON on stdin; drain it when piped so the
    # writer never blocks. We don't need its contents.
    [ -t 0 ] || cat >/dev/null 2>&1 || true

    gate_allows "$ALLOW_UNWRAPPED_FLAG" && exit 0

    # Exit 2 blocks the prompt and surfaces stderr to the user.
    echo "BLOCKED: Claude is running OUTSIDE the claude-sandbox bwrap shadow (IS_SANDBOX unset) — host credentials are NOT isolated. A Claude Code self-update can re-create ~/.local/bin/claude and bypass the shadow; re-run claude-sandbox/install, then relaunch claude. (To work unwrapped anyway, the host operator can: sudo touch /etc/claude-code/allow-unwrapped.)" >&2
    exit 2
}

# Run the gate only when EXECUTED directly, not when a test SOURCES this file to
# unit-test gate_allows(). The guard is BASH_SOURCE-vs-$0 — intrinsic to how the
# script is invoked, NOT an environment variable — so a confined Claude cannot
# set anything to skip the gate.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
    gate_main
fi
