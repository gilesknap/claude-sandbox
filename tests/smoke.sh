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

# Guard scripts placed OFF the rw set under /usr/libexec (prefixed),
# like the relocated real binary. Both executable, mode 0755.
VERIFY_DEST="$PREFIX/usr/libexec/claude-sandbox/sandbox-verify.sh"
GATE_DEST="$PREFIX/usr/libexec/claude-sandbox/sandbox-gate.sh"
for g in "$VERIFY_DEST" "$GATE_DEST"; do
    if [ -x "$g" ] && [ "$(stat -c '%a' "$g" 2>/dev/null)" = "755" ]; then
        pass
    else
        fail "guard script missing or not 0755-executable at $g"
    fi
done

# Managed settings (the highest-precedence, user-uneditable policy layer)
# carries the guard hooks + updater-disable.
MANAGED="$PREFIX/etc/claude-code/managed-settings.json"
if [ -f "$MANAGED" ] && jq -e . "$MANAGED" >/dev/null 2>&1; then
    pass
else
    fail "managed-settings.json missing or not valid JSON at $MANAGED"
fi
if jq -e 'any(.hooks.SessionStart[].hooks[]?; (.command // "") | endswith("sandbox-verify.sh"))' \
        "$MANAGED" >/dev/null 2>&1; then
    pass
else
    fail "managed-settings.json missing SessionStart sandbox-verify.sh entry"
fi
if jq -e 'any(.hooks.UserPromptSubmit[].hooks[]?; (.command // "") | endswith("sandbox-gate.sh"))' \
        "$MANAGED" >/dev/null 2>&1; then
    pass
else
    fail "managed-settings.json missing UserPromptSubmit sandbox-gate.sh entry"
fi
# Guard commands must point at the absolute /usr/libexec scripts (not $HOME).
if jq -e 'any(.. | .command? // empty; startswith("bash /usr/libexec/claude-sandbox/"))' \
        "$MANAGED" >/dev/null 2>&1; then
    pass
else
    fail "managed guard command does not point at /usr/libexec/claude-sandbox"
fi
# Auto-updater hard-disabled in managed settings.
if [ "$(jq -r '.env.DISABLE_AUTOUPDATER' "$MANAGED" 2>/dev/null)" = "1" ] \
        && [ "$(jq -r '.autoUpdates' "$MANAGED" 2>/dev/null)" = "false" ]; then
    pass
else
    fail "managed-settings.json missing env.DISABLE_AUTOUPDATER=1 / autoUpdates=false"
fi
# allowManagedHooksOnly must NOT be set — that would block the owner's
# own hooks, which is more than we want.
if [ "$(jq -r 'has("allowManagedHooksOnly")' "$MANAGED" 2>/dev/null)" = "false" ]; then
    pass
else
    fail "managed-settings.json set allowManagedHooksOnly (would block owner hooks)"
fi

# User-scope settings.json now holds ONLY the statusline preference — the
# guard must NOT be wired here.
SETTINGS="$USER_HOME_DIR/.claude/settings.json"
SL_DEST="$USER_HOME_DIR/.claude/statusline-command.sh"
if [ -x "$SL_DEST" ]; then
    pass
else
    fail "user-scope statusline not placed/executable at $SL_DEST"
fi
if [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
    pass
else
    fail "user settings.json missing or not valid JSON at $SETTINGS"
fi
if jq -e '(.statusLine.type == "command") and (.statusLine.command | endswith("statusline-command.sh"))' \
        "$SETTINGS" >/dev/null 2>&1; then
    pass
else
    fail "user settings.json missing/!command .statusLine"
fi
# The guard must NOT appear in user-scope settings.
if jq -e '[.. | .command? // empty | select(endswith("sandbox-verify.sh") or endswith("sandbox-gate.sh"))] | length == 0' \
        "$SETTINGS" >/dev/null 2>&1; then
    pass
else
    fail "guard hooks leaked into user-scope settings.json (should be managed-only)"
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
# shadow, both guard scripts, the managed-settings + user-settings jq
# merges (each must be a fixed point), and the conf.
declare -A SUM_A
for f in "$SHADOW_DEST" "$VERIFY_DEST" "$GATE_DEST" "$MANAGED" "$SETTINGS" "$CONF_DEST"; do
    SUM_A["$f"]="$(sha256sum "$f" | awk '{print $1}')"
done

if ! run_install; then
    fail "second install run exited non-zero"
fi

for f in "$SHADOW_DEST" "$VERIFY_DEST" "$GATE_DEST" "$MANAGED" "$SETTINGS" "$CONF_DEST"; do
    if [ "${SUM_A[$f]}" = "$(sha256sum "$f" | awk '{print $1}')" ]; then
        pass
    else
        fail "$f drifted across install re-run"
    fi
done

# Managed-settings merge with a pre-existing admin policy: a foreign key
# AND a foreign hook in the same events must be preserved; our guard is
# added (deduped); the merge is a fixed point.
MGD_PREFIX="$(mktemp -d)"
trap 'rm -rf "$PREFIX" "$WORKSPACE" "$USER_HOME_DIR" "$MGD_PREFIX"' EXIT
mkdir -p "$MGD_PREFIX/etc/claude-code"
cat > "$MGD_PREFIX/etc/claude-code/managed-settings.json" <<'JSON'
{
  "permissions": {"defaultMode": "plan"},
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "org-audit.sh"}]}]
  }
}
JSON
MGD="$MGD_PREFIX/etc/claude-code/managed-settings.json"
INSTALL_PREFIX="$MGD_PREFIX" INSTALL_USER_HOME="$(mktemp -d)" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1

if jq -e '.permissions.defaultMode == "plan"' "$MGD" >/dev/null 2>&1; then
    pass
else
    fail "managed merge dropped pre-existing admin key"
fi
if jq -e 'any(.hooks.SessionStart[].hooks[]?; .command == "org-audit.sh")' "$MGD" >/dev/null 2>&1; then
    pass
else
    fail "managed merge dropped pre-existing admin hook"
fi
if jq -e 'any(.hooks.SessionStart[].hooks[]?; (.command // "")|endswith("sandbox-verify.sh"))
          and any(.hooks.UserPromptSubmit[].hooks[]?; (.command // "")|endswith("sandbox-gate.sh"))' \
        "$MGD" >/dev/null 2>&1; then
    pass
else
    fail "managed merge did not add our guard alongside the admin hook"
fi

# Re-merge dedup: running again must NOT duplicate our entries.
INSTALL_PREFIX="$MGD_PREFIX" INSTALL_USER_HOME="$(mktemp -d)" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1
V_COUNT="$(jq '[.hooks.SessionStart[].hooks[] | select(.command|endswith("sandbox-verify.sh"))] | length' "$MGD")"
G_COUNT="$(jq '[.hooks.UserPromptSubmit[].hooks[] | select(.command|endswith("sandbox-gate.sh"))] | length' "$MGD")"
if [ "$V_COUNT" = "1" ] && [ "$G_COUNT" = "1" ]; then
    pass
else
    fail "duplicate managed guard entries after re-merge (verify=$V_COUNT gate=$G_COUNT)"
fi

# Migration: an earlier install that put the guard in USER-scope must be
# pruned so the guard has a single home (managed). Foreign user hooks +
# keys are preserved; the owner's statusline is respected.
MIG_HOME="$(mktemp -d)"
trap 'rm -rf "$PREFIX" "$WORKSPACE" "$USER_HOME_DIR" "$MGD_PREFIX" "$MIG_HOME"' EXIT
mkdir -p "$MIG_HOME/.claude"
cat > "$MIG_HOME/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "statusLine": {"type": "command", "command": "their-statusline.sh"},
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "bash $HOME/.claude/claude-sandbox/sandbox-verify.sh"}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "their-ups.sh"}]},
      {"hooks": [{"type": "command", "command": "bash $HOME/.claude/claude-sandbox/sandbox-gate.sh"}]}
    ]
  }
}
JSON
# Owner has a customised statusline script — install must not stomp it.
printf '#!/usr/bin/env bash\necho custom\n' > "$MIG_HOME/.claude/statusline-command.sh"
chmod 0755 "$MIG_HOME/.claude/statusline-command.sh"

INSTALL_USER_HOME="$MIG_HOME" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1
MIG="$MIG_HOME/.claude/settings.json"

if jq -e '[.. | .command? // empty | select(endswith("sandbox-verify.sh") or endswith("sandbox-gate.sh"))] | length == 0' \
        "$MIG" >/dev/null 2>&1; then
    pass
else
    fail "interim user-scope guard hooks were not pruned"
fi
if jq -e 'any(.hooks.UserPromptSubmit[].hooks[]?; .command == "their-ups.sh") and .model == "opus"' \
        "$MIG" >/dev/null 2>&1; then
    pass
else
    fail "prune dropped a foreign hook / key"
fi
if jq -e '.statusLine.command == "their-statusline.sh"' "$MIG" >/dev/null 2>&1; then
    pass
else
    fail "pre-existing .statusLine was overwritten during migration"
fi
if grep -qx 'echo custom' "$MIG_HOME/.claude/statusline-command.sh"; then
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
trap 'rm -rf "$PREFIX" "$WORKSPACE" "$USER_HOME_DIR" "$MGD_PREFIX" "$MIG_HOME" "$LINK_HOME" "$LINK_SHARED" "$ADOPT_HOME" "$ADOPT_SHARED" "$SEED_HOME" "$SEED_SHARED"' EXIT
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

# link_terminal_config ADOPT: a pre-existing *local* ~/.claude{,.json}
# (e.g. written by an unsandboxed claude / VS Code extension before
# install ran) must not shadow an already-populated shared store. The
# shared copy wins; the local one is backed up, not destroyed.
ADOPT_HOME="$(mktemp -d)"
ADOPT_SHARED="$(mktemp -d)"
SEED_HOME="$(mktemp -d)"
SEED_SHARED="$(mktemp -d)"
mkdir -p "$ADOPT_HOME/.claude" "$ADOPT_SHARED/.claude"
echo local  > "$ADOPT_HOME/.claude/marker";   printf 'local'  > "$ADOPT_HOME/.claude.json"
echo shared > "$ADOPT_SHARED/.claude/marker"; printf 'shared' > "$ADOPT_SHARED/.claude.json"
HOME="$ADOPT_HOME" CLAUDE_SHARED_CONFIG="$ADOPT_SHARED" \
    INSTALL_WORKSPACE="$WORKSPACE" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1
if [ "$(readlink "$ADOPT_HOME/.claude" 2>/dev/null)" = "$ADOPT_SHARED/.claude" ] \
        && [ "$(readlink "$ADOPT_HOME/.claude.json" 2>/dev/null)" = "$ADOPT_SHARED/.claude.json" ] \
        && [ "$(cat "$ADOPT_HOME/.claude/marker" 2>/dev/null)" = shared ] \
        && cat "$ADOPT_HOME"/.claude.pre-sandbox.*/marker 2>/dev/null | grep -qx local \
        && cat "$ADOPT_HOME"/.claude.json.pre-sandbox.* 2>/dev/null | grep -qx local; then
    pass
else
    fail "adopt: populated shared must win and local ~/.claude{,.json} be backed up"
fi

# link_terminal_config SEED: when the shared store is empty/absent, a
# real local ~/.claude{,.json} (carrying the first-run OAuth token) must
# be MOVED into the shared store as the baseline — never discarded.
mkdir -p "$SEED_HOME/.claude"
echo seedme > "$SEED_HOME/.claude/marker"
printf 'token-abc' > "$SEED_HOME/.claude.json"
HOME="$SEED_HOME" CLAUDE_SHARED_CONFIG="$SEED_SHARED" \
    INSTALL_WORKSPACE="$WORKSPACE" \
    bash "$REPO_ROOT/.devcontainer/claude-sandbox/install.sh" >/dev/null 2>&1
if [ "$(readlink "$SEED_HOME/.claude" 2>/dev/null)" = "$SEED_SHARED/.claude" ] \
        && [ "$(readlink "$SEED_HOME/.claude.json" 2>/dev/null)" = "$SEED_SHARED/.claude.json" ] \
        && [ "$(cat "$SEED_SHARED/.claude/marker" 2>/dev/null)" = seedme ] \
        && [ "$(cat "$SEED_SHARED/.claude.json" 2>/dev/null)" = token-abc ]; then
    pass
else
    fail "seed: empty shared must be seeded from local config without data loss"
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
