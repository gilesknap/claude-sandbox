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
# Installed at an ABSOLUTE path under ~/.claude so it resolves from any
# cwd (relative hook commands break once cwd != project root).
#
# Escape hatch: export CLAUDE_SANDBOX_ALLOW_UNWRAPPED=1 to downgrade to
# warn-only (the SessionStart hook still warns loudly). Skips on Claude
# Code Web (CLAUDE_CODE_REMOTE=true) — already sandboxed by Anthropic.
set -uo pipefail

# UserPromptSubmit delivers JSON on stdin; drain it when piped so the
# writer never blocks. We don't need its contents.
[ -t 0 ] || cat >/dev/null 2>&1 || true

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ]            && exit 0
[ "${IS_SANDBOX:-}" = "1" ]                       && exit 0
[ "${CLAUDE_SANDBOX_ALLOW_UNWRAPPED:-}" = "1" ]   && exit 0

# Exit 2 blocks the prompt and surfaces stderr to the user.
echo "BLOCKED: Claude is running OUTSIDE the claude-sandbox bwrap shadow (IS_SANDBOX unset) — host credentials are NOT isolated. A Claude Code self-update can re-create ~/.local/bin/claude and bypass the shadow; re-run claude-sandbox/install, then relaunch claude. (To work unwrapped anyway, set CLAUDE_SANDBOX_ALLOW_UNWRAPPED=1.)" >&2
exit 2
