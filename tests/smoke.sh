#!/usr/bin/env bash
# Install smoke test. Runs the installer with INSTALL_PREFIX +
# INSTALL_WORKSPACE pointed at fresh tmpdirs and asserts on the
# resulting file placement. Set CLAUDE_SANDBOX_SMOKE=1 to skip
# apt-install and the curl-install of the real Claude binary.
#
#   CLAUDE_SANDBOX_SMOKE=1 bash tests/smoke.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED+1)); }
fail() { FAILED=$((FAILED+1)); echo "FAIL: $1" >&2; }
assert_true()   { local name="$1"; shift; if "$@"; then pass; else fail "$name"; fi; }
file_sum()      { sha256sum "$1" | awk '{print $1}'; }
assert_stable() {
    local label="$1" a="$2" b="$3"
    if [ "$a" = "$b" ]; then pass; else fail "$label drifted across install re-run"; fi
}

PREFIX="$(mktemp -d)"
WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$PREFIX" "$WORKSPACE"' EXIT

export CLAUDE_SANDBOX_SMOKE=1
export INSTALL_PREFIX="$PREFIX"
export INSTALL_WORKSPACE="$WORKSPACE"

run_install() {
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1
}

# First install.
if ! run_install; then
    fail "first install run exited non-zero"
fi

# Shadow placement.
SHADOW_DEST="$PREFIX/usr/local/bin/claude"
assert_true "shadow not placed at $SHADOW_DEST" test -f "$SHADOW_DEST"
assert_true "shadow not executable"             test -x "$SHADOW_DEST"
# install(1) -m 0755 — check mode.
shadow_mode="$(stat -c '%a' "$SHADOW_DEST" 2>/dev/null)"
assert_true "shadow mode is $shadow_mode, expected 755" test "$shadow_mode" = "755"
# Shebang.
assert_true "shadow does not start with #!/usr/bin/env bash" \
    bash -c "head -1 '$SHADOW_DEST' | grep -qxF '#!/usr/bin/env bash'"

# Workspace hook placement.
HOOK_DEST="$WORKSPACE/.claude/hooks/sandbox-check.sh"
assert_true "workspace hook not placed at $HOOK_DEST" test -f "$HOOK_DEST"
assert_true "workspace hook not executable"            test -x "$HOOK_DEST"

# Workspace statusline placement.
SL_DEST="$WORKSPACE/.claude/statusline-command.sh"
assert_true "workspace statusline not placed at $SL_DEST" test -f "$SL_DEST"
assert_true "workspace statusline not executable"          test -x "$SL_DEST"
sl_mode="$(stat -c '%a' "$SL_DEST" 2>/dev/null)"
assert_true "statusline mode is $sl_mode, expected 755"    test "$sl_mode" = "755"

# Settings.json placement + content.
SETTINGS="$WORKSPACE/.claude/settings.json"
assert_true "settings.json not placed at $SETTINGS" test -f "$SETTINGS"
assert_true "settings.json does not parse as JSON"  jq -e . "$SETTINGS" >/dev/null 2>&1
assert_true "settings.json missing UserPromptSubmit sandbox-check.sh entry" bash -c "
    jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' '$SETTINGS' 2>/dev/null \
        | grep -qx '.claude/hooks/sandbox-check.sh'"
assert_true "settings.json missing .statusLine.command entry" bash -c "
    jq -r '.statusLine.command' '$SETTINGS' 2>/dev/null \
        | grep -qx '.claude/statusline-command.sh'"
assert_true "settings.json .statusLine.type is not 'command'" bash -c "
    [ \"\$(jq -r '.statusLine.type' '$SETTINGS' 2>/dev/null)\" = 'command' ]"

# Config placement: install copies the clone's conf to the host-global
# /etc/claude-sandbox.conf the shadow reads at launch (prefixed for the
# tmpdir). Skip-if-absent in install_conf means this only asserts when
# the clone actually carries a conf — which it does in-tree.
CONF_DEST="$PREFIX/etc/claude-sandbox.conf"
CONF_SRC="$REPO_ROOT/.devcontainer/claude-sandbox.conf"
assert_true "config not placed at $CONF_DEST"     test -f "$CONF_DEST"
assert_true "installed config differs from source" cmp -s "$CONF_SRC" "$CONF_DEST"

# Idempotency: second install must be byte-for-byte stable.
SHADOW_SUM_A="$(file_sum "$SHADOW_DEST")"
HOOK_SUM_A="$(file_sum "$HOOK_DEST")"
SL_SUM_A="$(file_sum "$SL_DEST")"
SETTINGS_SUM_A="$(file_sum "$SETTINGS")"
CONF_SUM_A="$(file_sum "$CONF_DEST")"

assert_true "second install run exited non-zero" run_install

assert_stable "shadow"        "$SHADOW_SUM_A"   "$(file_sum "$SHADOW_DEST")"
assert_stable "workspace hook" "$HOOK_SUM_A"    "$(file_sum "$HOOK_DEST")"
assert_stable "statusline"    "$SL_SUM_A"       "$(file_sum "$SL_DEST")"
assert_stable "settings.json" "$SETTINGS_SUM_A" "$(file_sum "$SETTINGS")"
assert_stable "config"        "$CONF_SUM_A"     "$(file_sum "$CONF_DEST")"

# Settings merge with pre-existing JSON: write a settings.json with
# unrelated keys, re-run, assert merge preserves them and dedups our hook.
MERGE_WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$PREFIX" "$WORKSPACE" "$MERGE_WORKSPACE"' EXIT
mkdir -p "$MERGE_WORKSPACE/.claude"
cat > "$MERGE_WORKSPACE/.claude/settings.json" <<'JSON'
{
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "some-other-hook.sh"}]}
    ]
  }
}
JSON

INSTALL_WORKSPACE="$MERGE_WORKSPACE" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1

if jq -e '.permissions.allow[0] == "Bash(ls:*)"' \
        "$MERGE_WORKSPACE/.claude/settings.json" >/dev/null 2>&1; then
    pass
else
    fail "merge dropped pre-existing permissions"
fi
if jq -e 'any(.hooks.UserPromptSubmit[].hooks[]; .command == ".claude/hooks/sandbox-check.sh")' \
        "$MERGE_WORKSPACE/.claude/settings.json" >/dev/null 2>&1; then
    pass
else
    fail "merge did not add our sandbox-check.sh hook"
fi
if jq -e 'any(.hooks.UserPromptSubmit[].hooks[]; .command == "some-other-hook.sh")' \
        "$MERGE_WORKSPACE/.claude/settings.json" >/dev/null 2>&1; then
    pass
else
    fail "merge dropped pre-existing hook"
fi

# Re-merge dedup: running again must NOT duplicate our entry.
INSTALL_WORKSPACE="$MERGE_WORKSPACE" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1
OUR_HOOK_COUNT="$(jq '[.hooks.UserPromptSubmit[].hooks[] | select(.command == ".claude/hooks/sandbox-check.sh")] | length' \
    "$MERGE_WORKSPACE/.claude/settings.json")"
if [ "$OUR_HOOK_COUNT" = "1" ]; then
    pass
else
    fail "duplicate sandbox-check.sh entries after re-merge (count=$OUR_HOOK_COUNT)"
fi

# Statusline merge must have added our .statusLine alongside the
# pre-existing permissions/hooks.
if jq -e '.statusLine.command == ".claude/statusline-command.sh"' \
        "$MERGE_WORKSPACE/.claude/settings.json" >/dev/null 2>&1; then
    pass
else
    fail "merge did not add our .statusLine block"
fi
if jq -e '.permissions.allow[0] == "Bash(ls:*)"' \
        "$MERGE_WORKSPACE/.claude/settings.json" >/dev/null 2>&1; then
    pass
else
    fail "statusline merge dropped pre-existing permissions"
fi

# Pre-existing .statusLine policy: respect it. Install still completes
# (hook is wired) but the user's statusLine is left untouched.
RESPECT_WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$PREFIX" "$WORKSPACE" "$MERGE_WORKSPACE" "$RESPECT_WORKSPACE"' EXIT
mkdir -p "$RESPECT_WORKSPACE/.claude"
cat > "$RESPECT_WORKSPACE/.claude/settings.json" <<'JSON'
{
  "statusLine": {"type": "command", "command": "their-statusline.sh"}
}
JSON

if INSTALL_WORKSPACE="$RESPECT_WORKSPACE" \
        bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" \
        >/dev/null 2>&1; then
    pass
else
    fail "install refused a workspace with a pre-existing .statusLine"
fi
if jq -e '.statusLine.command == "their-statusline.sh"' \
        "$RESPECT_WORKSPACE/.claude/settings.json" >/dev/null 2>&1; then
    pass
else
    fail "pre-existing .statusLine was overwritten"
fi
if jq -e 'any(.hooks.UserPromptSubmit[].hooks[]; .command == ".claude/hooks/sandbox-check.sh")' \
        "$RESPECT_WORKSPACE/.claude/settings.json" >/dev/null 2>&1; then
    pass
else
    fail "hook wiring did not run on a workspace with pre-existing .statusLine"
fi

# link_terminal_config: with CLAUDE_SHARED_CONFIG pointing at a fake
# shared dir and HOME pointing at a fresh tmpdir, install must create
# symlinks at $HOME/.claude{,.json} into the shared dir.
LINK_HOME="$(mktemp -d)"
LINK_SHARED="$(mktemp -d)"
trap 'rm -rf "$PREFIX" "$WORKSPACE" "$MERGE_WORKSPACE" "$RESPECT_WORKSPACE" "$LINK_HOME" "$LINK_SHARED"' EXIT
HOME="$LINK_HOME" CLAUDE_SHARED_CONFIG="$LINK_SHARED" \
    INSTALL_WORKSPACE="$WORKSPACE" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1
if [ "$(readlink "$LINK_HOME/.claude" 2>/dev/null)" = "$LINK_SHARED/.claude" ] \
        && [ "$(readlink "$LINK_HOME/.claude.json" 2>/dev/null)" = "$LINK_SHARED/.claude.json" ]; then
    pass
else
    fail "link_terminal_config did not symlink ~/.claude{,.json} into $LINK_SHARED"
fi

# Bwrap sanity check (when bwrap is available AND we are not already
# inside a sandbox — nested userns is forbidden). CI installs bwrap as
# a pre-step; locally we tolerate absence or nesting as a skip.
if command -v bwrap >/dev/null 2>&1 && [ "${IS_SANDBOX:-}" != "1" ]; then
    if bwrap --ro-bind / / -- /bin/true >/dev/null 2>&1; then
        pass
    else
        fail "bwrap --ro-bind / / -- /bin/true failed (runner cannot enter a sandbox)"
    fi
fi

echo "smoke.sh: $PASSED passed / $FAILED failed"
[ "$FAILED" -eq 0 ]
