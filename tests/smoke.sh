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
fail() {
    FAILED=$((FAILED+1))
    echo "FAIL: $1" >&2
}

PREFIX="$(mktemp -d)"
WORKSPACE="$(mktemp -d)"
# USER_HOME is the user-scope ~/.claude home the GLOBAL guard merges
# into. Pin it at a tmpdir so the suite NEVER touches the real
# ~/.claude/settings.json of whoever runs the test.
USER_HOME_DIR="$(mktemp -d)"
trap 'rm -rf "$PREFIX" "$WORKSPACE" "$USER_HOME_DIR"' EXIT

export CLAUDE_SANDBOX_SMOKE=1
export INSTALL_PREFIX="$PREFIX"
export INSTALL_WORKSPACE="$WORKSPACE"
export INSTALL_USER_HOME="$USER_HOME_DIR"

run_install() {
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1
}

# First install.
if ! run_install; then
    fail "first install run exited non-zero"
fi

# Shadow placement.
SHADOW_DEST="$PREFIX/usr/local/bin/claude"
if [ -f "$SHADOW_DEST" ]; then
    pass
else
    fail "shadow not placed at $SHADOW_DEST"
fi

if [ -x "$SHADOW_DEST" ]; then
    pass
else
    fail "shadow not executable"
fi

# install(1) -m 0755 — check mode.
if [ "$(stat -c '%a' "$SHADOW_DEST" 2>/dev/null)" = "755" ]; then
    pass
else
    fail "shadow mode is $(stat -c '%a' "$SHADOW_DEST" 2>/dev/null), expected 755"
fi

# Shebang.
if head -1 "$SHADOW_DEST" | grep -qxF '#!/usr/bin/env bash'; then
    pass
else
    fail "shadow does not start with #!/usr/bin/env bash"
fi

# GLOBAL guard scripts placed at absolute paths under the user-scope
# ~/.claude (NOT per-workspace). Both must be executable, mode 0755.
VERIFY_DEST="$USER_HOME_DIR/.claude/claude-sandbox/sandbox-verify.sh"
GATE_DEST="$USER_HOME_DIR/.claude/claude-sandbox/sandbox-gate.sh"
for g in "$VERIFY_DEST" "$GATE_DEST"; do
    if [ -x "$g" ] && [ "$(stat -c '%a' "$g" 2>/dev/null)" = "755" ]; then
        pass
    else
        fail "guard script missing or not 0755-executable at $g"
    fi
done

# User-scope statusline placement (seeded only-if-absent on a fresh home).
SL_DEST="$USER_HOME_DIR/.claude/statusline-command.sh"
if [ -x "$SL_DEST" ]; then
    pass
else
    fail "user-scope statusline not placed/executable at $SL_DEST"
fi

# User-scope settings.json: placement + content.
SETTINGS="$USER_HOME_DIR/.claude/settings.json"
if [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
    pass
else
    fail "user settings.json missing or not valid JSON at $SETTINGS"
fi

if jq -e 'any(.hooks.SessionStart[].hooks[]?; (.command // "") | endswith("sandbox-verify.sh"))' \
        "$SETTINGS" >/dev/null 2>&1; then
    pass
else
    fail "settings.json missing SessionStart sandbox-verify.sh entry"
fi

if jq -e 'any(.hooks.UserPromptSubmit[].hooks[]?; (.command // "") | endswith("sandbox-gate.sh"))' \
        "$SETTINGS" >/dev/null 2>&1; then
    pass
else
    fail "settings.json missing UserPromptSubmit sandbox-gate.sh entry"
fi

# Auto-updater hard-disabled (root-cause removal of the bypass re-arm).
if [ "$(jq -r '.env.DISABLE_AUTOUPDATER' "$SETTINGS" 2>/dev/null)" = "1" ]; then
    pass
else
    fail "settings.json missing env.DISABLE_AUTOUPDATER=1"
fi
if [ "$(jq -r '.autoUpdates' "$SETTINGS" 2>/dev/null)" = "false" ]; then
    pass
else
    fail "settings.json missing autoUpdates=false"
fi

# statusLine wired (absolute command) on a fresh home.
if jq -e '(.statusLine.type == "command") and (.statusLine.command | endswith("statusline-command.sh"))' \
        "$SETTINGS" >/dev/null 2>&1; then
    pass
else
    fail "settings.json missing/!command .statusLine"
fi

# Config placement: install copies the clone's conf to the host-global
# /etc/claude-sandbox.conf the shadow reads at launch (prefixed for the
# tmpdir). Skip-if-absent in install_conf means this only asserts when
# the clone actually carries a conf — which it does in-tree.
CONF_DEST="$PREFIX/etc/claude-sandbox.conf"
CONF_SRC="$REPO_ROOT/.devcontainer/claude-sandbox.conf"
if [ -f "$CONF_DEST" ]; then
    pass
else
    fail "config not placed at $CONF_DEST"
fi
if cmp -s "$CONF_SRC" "$CONF_DEST"; then
    pass
else
    fail "installed config differs from source conf"
fi

# Idempotency: second install must be byte-for-byte stable across the
# shadow, both global guard scripts, the user settings.json (the jq
# merge must be a fixed point), and the conf.
declare -A SUM_A
for f in "$SHADOW_DEST" "$VERIFY_DEST" "$GATE_DEST" "$SETTINGS" "$CONF_DEST"; do
    SUM_A["$f"]="$(sha256sum "$f" | awk '{print $1}')"
done

if ! run_install; then
    fail "second install run exited non-zero"
fi

for f in "$SHADOW_DEST" "$VERIFY_DEST" "$GATE_DEST" "$SETTINGS" "$CONF_DEST"; do
    if [ "${SUM_A[$f]}" = "$(sha256sum "$f" | awk '{print $1}')" ]; then
        pass
    else
        fail "$f drifted across install re-run"
    fi
done

# User-scope merge with pre-existing JSON: write a settings.json with
# unrelated keys AND a foreign hook in the same events, run, assert the
# merge preserves everything and adds (without duplicating) our guard.
MERGE_HOME="$(mktemp -d)"
trap 'rm -rf "$PREFIX" "$WORKSPACE" "$USER_HOME_DIR" "$MERGE_HOME"' EXIT
mkdir -p "$MERGE_HOME/.claude"
cat > "$MERGE_HOME/.claude/settings.json" <<'JSON'
{
  "permissions": {"allow": ["Bash(ls:*)"]},
  "model": "opus",
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "their-start.sh"}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "their-ups.sh"}]}
    ]
  }
}
JSON

MERGED="$MERGE_HOME/.claude/settings.json"
INSTALL_USER_HOME="$MERGE_HOME" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1

if jq -e '.permissions.allow[0] == "Bash(ls:*)" and .model == "opus"' \
        "$MERGED" >/dev/null 2>&1; then
    pass
else
    fail "user merge dropped pre-existing keys"
fi
if jq -e 'any(.hooks.SessionStart[].hooks[]?; .command == "their-start.sh")
          and any(.hooks.UserPromptSubmit[].hooks[]?; .command == "their-ups.sh")' \
        "$MERGED" >/dev/null 2>&1; then
    pass
else
    fail "user merge dropped pre-existing foreign hooks"
fi
if jq -e 'any(.hooks.SessionStart[].hooks[]?; (.command // "")|endswith("sandbox-verify.sh"))
          and any(.hooks.UserPromptSubmit[].hooks[]?; (.command // "")|endswith("sandbox-gate.sh"))' \
        "$MERGED" >/dev/null 2>&1; then
    pass
else
    fail "user merge did not add our guard hooks alongside the foreign ones"
fi
if [ "$(jq -r '.env.DISABLE_AUTOUPDATER' "$MERGED")" = "1" ] \
        && [ "$(jq -r '.autoUpdates' "$MERGED")" = "false" ]; then
    pass
else
    fail "user merge did not set DISABLE_AUTOUPDATER/autoUpdates"
fi

# Re-merge dedup: running again must NOT duplicate our entries.
INSTALL_USER_HOME="$MERGE_HOME" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1
V_COUNT="$(jq '[.hooks.SessionStart[].hooks[] | select(.command|endswith("sandbox-verify.sh"))] | length' "$MERGED")"
G_COUNT="$(jq '[.hooks.UserPromptSubmit[].hooks[] | select(.command|endswith("sandbox-gate.sh"))] | length' "$MERGED")"
if [ "$V_COUNT" = "1" ] && [ "$G_COUNT" = "1" ]; then
    pass
else
    fail "duplicate guard entries after re-merge (verify=$V_COUNT gate=$G_COUNT)"
fi

# Pre-existing .statusLine policy: respect it (set-only-if-absent). The
# guard hooks still get wired; the owner's statusLine is left untouched.
RESPECT_HOME="$(mktemp -d)"
trap 'rm -rf "$PREFIX" "$WORKSPACE" "$USER_HOME_DIR" "$MERGE_HOME" "$RESPECT_HOME"' EXIT
mkdir -p "$RESPECT_HOME/.claude"
cat > "$RESPECT_HOME/.claude/settings.json" <<'JSON'
{
  "statusLine": {"type": "command", "command": "their-statusline.sh"}
}
JSON
# Owner also has a customised statusline script — install must not stomp it.
printf '#!/usr/bin/env bash\necho custom\n' > "$RESPECT_HOME/.claude/statusline-command.sh"
chmod 0755 "$RESPECT_HOME/.claude/statusline-command.sh"

if INSTALL_USER_HOME="$RESPECT_HOME" \
        bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" \
        >/dev/null 2>&1; then
    pass
else
    fail "install failed on a home with a pre-existing .statusLine"
fi
if jq -e '.statusLine.command == "their-statusline.sh"' \
        "$RESPECT_HOME/.claude/settings.json" >/dev/null 2>&1; then
    pass
else
    fail "pre-existing .statusLine was overwritten"
fi
if jq -e 'any(.hooks.SessionStart[].hooks[]?; (.command // "")|endswith("sandbox-verify.sh"))' \
        "$RESPECT_HOME/.claude/settings.json" >/dev/null 2>&1; then
    pass
else
    fail "guard wiring did not run on a home with pre-existing .statusLine"
fi
# The owner's customised statusline script must survive (only-if-absent).
if grep -qx 'echo custom' "$RESPECT_HOME/.claude/statusline-command.sh"; then
    pass
else
    fail "install_file_if_absent overwrote a pre-existing statusline script"
fi

# link_terminal_config: with CLAUDE_SHARED_CONFIG pointing at a fake
# shared dir and HOME pointing at a fresh tmpdir, install must create
# symlinks at $HOME/.claude{,.json} into the shared dir. INSTALL_USER_HOME
# stays pinned at the global tmpdir so the guard merge never touches HOME.
LINK_HOME="$(mktemp -d)"
LINK_SHARED="$(mktemp -d)"
trap 'rm -rf "$PREFIX" "$WORKSPACE" "$USER_HOME_DIR" "$MERGE_HOME" "$RESPECT_HOME" "$LINK_HOME" "$LINK_SHARED"' EXIT
HOME="$LINK_HOME" CLAUDE_SHARED_CONFIG="$LINK_SHARED" \
    INSTALL_WORKSPACE="$WORKSPACE" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1
if [ "$(readlink "$LINK_HOME/.claude" 2>/dev/null)" = "$LINK_SHARED/.claude" ] \
        && [ "$(readlink "$LINK_HOME/.claude.json" 2>/dev/null)" = "$LINK_SHARED/.claude.json" ]; then
    pass
else
    fail "link_terminal_config did not symlink ~/.claude{,.json} into $LINK_SHARED"
fi

# Guard behaviour: drive the INSTALLED scripts directly (deterministic,
# env-only — no claude needed). The gate fail-closes when unwrapped and
# passes when wrapped or escape-hatched; the verifier warns loudly when
# unwrapped and never blocks.
echo '{}' | env -u IS_SANDBOX bash "$GATE_DEST" >/dev/null 2>&1
[ "$?" -eq 2 ] && pass || fail "gate did not block (exit 2) when unwrapped"

echo '{}' | env IS_SANDBOX=1 bash "$GATE_DEST" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass || fail "gate did not pass (exit 0) when wrapped"

echo '{}' | env -u IS_SANDBOX CLAUDE_SANDBOX_ALLOW_UNWRAPPED=1 bash "$GATE_DEST" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass || fail "gate did not honour CLAUDE_SANDBOX_ALLOW_UNWRAPPED escape hatch"

echo '{}' | env -u IS_SANDBOX CLAUDE_CODE_REMOTE=true bash "$GATE_DEST" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass || fail "gate did not skip on Claude Code Web"

VERIFY_OUT="$(echo '{}' | env -u IS_SANDBOX bash "$VERIFY_DEST" 2>/dev/null)"
VERIFY_RC=$?
if [ "$VERIFY_RC" -eq 0 ] && printf '%s' "$VERIFY_OUT" | grep -q 'OUTSIDE the bwrap shadow'; then
    pass
else
    fail "verifier did not emit a non-blocking warning when unwrapped (rc=$VERIFY_RC)"
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
