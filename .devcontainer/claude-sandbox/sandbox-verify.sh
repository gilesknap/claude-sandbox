#!/usr/bin/env bash
# SessionStart hook (user-scope, GLOBAL). Verifies the claude-sandbox
# bwrap shadow is actually in effect and warns LOUDLY when it is not.
#
# Why user-scope and not a project .claude/ hook: this guard must fire
# in EVERY folder, including ones with no project .claude/. User-scope
# hooks are read by the real `claude` binary in every cwd — even when a
# Claude Code self-update has re-created ~/.local/bin/claude and the
# shadow has been bypassed. installed at an ABSOLUTE path under
# ~/.claude (relative hook commands break once cwd != project root).
#
# SessionStart CANNOT block a session — it can only inject context /
# messages. The companion UserPromptSubmit gate (sandbox-gate.sh) is
# what actually fail-closes when unwrapped. This script does the heavy
# lifting (the full integrity battery) once per session; the gate stays
# lean. Skips on Claude Code Web (CLAUDE_CODE_REMOTE=true) — that
# runtime is already sandboxed by Anthropic and IS_SANDBOX is never set
# there.
set -uo pipefail

# SessionStart delivers a JSON event on stdin. Drain it (only when stdin
# is a pipe, not a tty) so the writer never blocks, then ignore it.
[ -t 0 ] || cat >/dev/null 2>&1 || true

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && exit 0

# emit: surface a message to the user (systemMessage) AND to Claude
# (additionalContext). Uses jq for safe JSON when available; falls back
# to stderr (which SessionStart shows to the user) if jq is missing.
emit() {
    local msg="$1" ctx="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg msg "$msg" --arg ctx "$ctx" \
            '{systemMessage:$msg, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}'
    else
        printf '%s\n' "$msg" >&2
    fi
}

REINSTALL='Re-run claude-sandbox/install (the official Claude Code auto-updater can re-create ~/.local/bin/claude and silently bypass the shadow), then relaunch claude.'

# The single load-bearing assertion: IS_SANDBOX=1 is set only by the
# bwrap launcher. Unset == we are NOT inside the shadow.
if [ "${IS_SANDBOX:-}" != "1" ]; then
    emit \
        "⚠️  claude-sandbox: Claude is running OUTSIDE the bwrap shadow — host credentials, env vars and dotfiles are NOT isolated. ${REINSTALL}" \
        "SECURITY WARNING: IS_SANDBOX is not set, so this session is NOT inside the claude-sandbox bwrap jail. Host credentials are reachable. ${REINSTALL}"
    exit 0
fi

# Inside the shadow — run the deeper integrity assertions once per
# session. Each only makes sense once IS_SANDBOX=1; any failure is a
# regression in the bwrap argv builder or the --clearenv allow-list.
problems=()
[ ! -s "$HOME/.gitconfig" ]                          || problems+=("host \$HOME/.gitconfig is readable (strict-under-/root regressed)")
[ -z "${GH_TOKEN:-}" ]                               || problems+=("GH_TOKEN leaked into the sandbox")
[ -z "${GITHUB_TOKEN:-}" ]                           || problems+=("GITHUB_TOKEN leaked into the sandbox")
[ -z "${ANTHROPIC_API_KEY:-}" ]                      || problems+=("ANTHROPIC_API_KEY leaked into the sandbox")
[ -z "${SSH_AUTH_SOCK:-}" ]                          || problems+=("SSH_AUTH_SOCK leaked into the sandbox")
[ -z "${DISPLAY:-}" ]                                || problems+=("DISPLAY leaked into the sandbox")
[ "${GIT_CONFIG_GLOBAL:-}" = "/etc/claude-gitconfig" ] || problems+=("GIT_CONFIG_GLOBAL is not /etc/claude-gitconfig")
[ "${GIT_CONFIG_SYSTEM:-}" = "/dev/null" ]           || problems+=("GIT_CONFIG_SYSTEM is not /dev/null")
if [ -d /run/secrets ] && [ -n "$(ls -A /run/secrets 2>/dev/null)" ]; then
    problems+=("/run/secrets is non-empty (Docker/Compose secrets reachable)")
fi

if [ "${#problems[@]}" -gt 0 ]; then
    msg="⚠️  claude-sandbox: inside the shadow but integrity checks FAILED: $(IFS='; '; printf '%s' "${problems[*]}"). Run /verify-sandbox, then re-run claude-sandbox/install."
    emit "$msg" "$msg"
    exit 0
fi

# Wrapped and intact — stay silent (no output == clean SessionStart).
exit 0
