#!/usr/bin/env bash
# Bash unit test for the bwrap_argv_build function defined inline in
# .devcontainer/claude-sandbox/claude-shadow. The shadow exposes a
# CLAUDE_SHADOW_SOURCE_ONLY=1 guard so we can source the function
# definitions without running the launch body.
#
# We assert on the argv as a contract with bwrap (line-equality grep),
# not on the internal control flow that built it. Failures print a
# diff-friendly diagnostic.
#
# Run via `bash tests/bwrap_argv.sh`.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHADOW="$REPO_ROOT/.devcontainer/claude-sandbox/claude-shadow"

if [ ! -f "$SHADOW" ]; then
    echo "FAIL: cannot find $SHADOW" >&2
    exit 1
fi

# Shared assertions + PASS/FAIL counters + register_cleanup.
# shellcheck source=lib.sh
source "$REPO_ROOT/tests/lib.sh"

# Pull bwrap_argv_build into scope without running the shadow's launch
# body. The shadow returns early when CLAUDE_SHADOW_SOURCE_ONLY=1.
export CLAUDE_SHADOW_SOURCE_ONLY=1
# shellcheck source=../.devcontainer/claude-sandbox/claude-shadow
source "$SHADOW"

# Normalise the runner's env so the pure-function assertions are
# deterministic regardless of where the suite is run. The shadow passes
# VIRTUAL_ENV / UV_* / PRE_COMMIT_HOME through and appends $VIRTUAL_ENV/bin
# to PATH — running the suite from inside an activated venv (e.g. the
# dogfood devcontainer) would otherwise leak that into Scenario 1's
# canonical-PATH assertion. Scenarios that exercise these vars set them
# explicitly in their own subshell, so clearing them here is safe.
unset VIRTUAL_ENV UV_PROJECT_ENVIRONMENT UV_CACHE_DIR UV_PYTHON_CACHE_DIR \
      PRE_COMMIT_HOME CLAUDE_SANDBOX_WORKSPACE_ROOT CLAUDE_SANDBOX_NO_FORGE \
      CLAUDE_SANDBOX_ALLOW_WRITE CLAUDE_SANDBOX_EGRESS_JAIL CLAUDE_SANDBOX_ALLOW_IP

# --- Scenario 1: vanilla (workspace=/workspaces/foo, $HOME=/root) ---
unset TERM LANG LC_ALL LC_CTYPE LC_MESSAGES LC_TIME LC_COLLATE LC_NUMERIC LC_MONETARY
ARGV1="$(HOME=/root CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    bwrap_argv_build /workspaces/foo /test/.local/bin/claude)"

assert_contains scenario1 "$ARGV1" "bwrap"
assert_contains scenario1 "$ARGV1" "--ro-bind"
assert_contains scenario1 "$ARGV1" "--dev"
assert_contains scenario1 "$ARGV1" "/dev"
# Unconditional --ro-bind /proc /proc.
assert_pair scenario1 "$ARGV1" "--ro-bind" "/proc"
assert_contains scenario1 "$ARGV1" "--cap-drop"
assert_contains scenario1 "$ARGV1" "ALL"
# All five unshare flags including --unshare-user-try.
assert_contains scenario1 "$ARGV1" "--unshare-user-try"
assert_contains scenario1 "$ARGV1" "--unshare-pid"
assert_contains scenario1 "$ARGV1" "--unshare-ipc"
assert_contains scenario1 "$ARGV1" "--unshare-uts"
assert_contains scenario1 "$ARGV1" "--unshare-cgroup-try"
assert_contains scenario1 "$ARGV1" "--die-with-parent"
# --new-session is DROPPED (delegated to script(1) wrap).
assert_not_contains scenario1 "$ARGV1" "--new-session"
# The shadow's procfs probe is gone — no --proc primitive emission.
assert_not_contains scenario1 "$ARGV1" "--proc"
# Env scrub.
assert_contains scenario1 "$ARGV1" "--clearenv"
assert_contains scenario1 "$ARGV1" "PATH"
assert_contains scenario1 "$ARGV1" "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin"
assert_contains scenario1 "$ARGV1" "HOME"
assert_contains scenario1 "$ARGV1" "/root"
assert_contains scenario1 "$ARGV1" "USER"
assert_contains scenario1 "$ARGV1" "root"
assert_contains scenario1 "$ARGV1" "IS_SANDBOX"
assert_contains scenario1 "$ARGV1" "GIT_CONFIG_GLOBAL"
assert_contains scenario1 "$ARGV1" "/etc/claude-gitconfig"
assert_contains scenario1 "$ARGV1" "GIT_CONFIG_SYSTEM"
assert_contains scenario1 "$ARGV1" "/dev/null"
# Final terminator and real claude path. The real binary is bound
# from its off-PATH host location to the conventional in-sandbox
# ~/.local/bin/claude, and bwrap execs the in-sandbox path.
assert_contains scenario1 "$ARGV1" "--"
assert_contains scenario1 "$ARGV1" "/test/.local/bin/claude"
assert_pair scenario1 "$ARGV1" "--bind" "/test/.local/bin/claude"
assert_contains scenario1 "$ARGV1" "/root/.local/bin/claude"
# /run/secrets mask only when the host has it.
if [ -d /run/secrets ]; then
    assert_contains scenario1 "$ARGV1" "/run/secrets"
else
    assert_not_contains scenario1 "$ARGV1" "/run/secrets"
fi

# --- Scenario 2: workspace empty string → no workspace bind line ---
ARGV2="$(HOME=/root CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    bwrap_argv_build "" /test/.local/bin/claude)"
# No bind for an empty workspace. The argv is otherwise intact.
assert_contains scenario2 "$ARGV2" "bwrap"
assert_contains scenario2 "$ARGV2" "--clearenv"
# Nothing that looks like a path bind for /tmp/... or /workspaces/... should appear.
# We can't enumerate all possible non-emissions, but workspace=""
# means the workspace bind branch is skipped.

# --- Scenario 3: workspace at an unusual non-existent path ---
ARGV3="$(HOME=/root CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    bwrap_argv_build /srv/weird-workspace-path /test/.local/bin/claude)"
assert_not_contains scenario3 "$ARGV3" "/srv/weird-workspace-path"

# --- Scenario 4: bind-back loop over $HOME (tmpdir-based fixture) ---
TMPHOME="$(mktemp -d)"
register_cleanup "$TMPHOME"
mkdir -p "$TMPHOME/.claude" "$TMPHOME/.config/gh"

ARGV4a="$(HOME="$TMPHOME" CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    bwrap_argv_build "$TMPHOME" /test/.local/bin/claude)"
assert_contains scenario4a "$ARGV4a" "$TMPHOME/.claude"
assert_contains scenario4a "$ARGV4a" "$TMPHOME/.config/gh"
# Absent paths must NOT appear.
assert_not_contains scenario4a "$ARGV4a" "$TMPHOME/.cache"
assert_not_contains scenario4a "$ARGV4a" "$TMPHOME/.config/glab-cli"
assert_not_contains scenario4a "$ARGV4a" "$TMPHOME/.local/share"
assert_not_contains scenario4a "$ARGV4a" "$TMPHOME/.local/share/applications"
assert_not_contains scenario4a "$ARGV4a" "$TMPHOME/.local/share/claude"
assert_not_contains scenario4a "$ARGV4a" "$TMPHOME/.claude.json"
assert_not_contains scenario4a "$ARGV4a" "$TMPHOME/.local/bin/uv"
assert_not_contains scenario4a "$ARGV4a" "$TMPHOME/.local/bin/uvx"
# Note: $TMPHOME/.local/bin/claude IS expected — it's the unconditional
# bind dest for the off-PATH real binary, regardless of $HOME state.
assert_contains scenario4a "$ARGV4a" "$TMPHOME/.local/bin/claude"

# Now populate the full set and re-check.
mkdir -p "$TMPHOME/.cache" "$TMPHOME/.config/glab-cli" "$TMPHOME/.local/share/helm" "$TMPHOME/.local/bin"
touch "$TMPHOME/.claude.json" "$TMPHOME/.local/bin/uv" "$TMPHOME/.local/bin/uvx" "$TMPHOME/.local/bin/claude"
# A sibling under .config (e.g. VS Code) must NOT be bound even when
# present — only the explicit allowlist is exposed.
mkdir -p "$TMPHOME/.config/Code"

ARGV4b="$(HOME="$TMPHOME" CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    bwrap_argv_build "$TMPHOME" /test/.local/bin/claude)"
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.claude"
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.cache"
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.config/gh"
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.config/glab-cli"
# .local/share is bulk-bound, with applications/ + claude/ tmpfs-masked.
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.local/share"
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.local/share/applications"
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.local/share/claude"
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.claude.json"
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.local/bin/uv"
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.local/bin/uvx"
assert_contains scenario4b "$ARGV4b" "$TMPHOME/.local/bin/claude"
assert_not_contains scenario4b "$ARGV4b" "$TMPHOME/.config/Code"
# Workspace ($TMPHOME exists) IS bound.
# (--bind <src> <dst> emits the path twice; existence is enough.)

# --- Scenario 5: pass-through env (TERM, LANG) appear as --setenv pairs ---
ARGV5="$(HOME=/root CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    TERM=xterm-256color LANG=en_US.UTF-8 \
    bwrap_argv_build /workspaces/foo /test/.local/bin/claude)"
assert_contains scenario5 "$ARGV5" "TERM"
assert_contains scenario5 "$ARGV5" "xterm-256color"
assert_contains scenario5 "$ARGV5" "LANG"
assert_contains scenario5 "$ARGV5" "en_US.UTF-8"

# --- Scenario 6: defence-in-depth masks at $HOME ---
assert_contains scenario6 "$ARGV1" "/root/.netrc"
assert_contains scenario6 "$ARGV1" "/root/.Xauthority"
assert_contains scenario6 "$ARGV1" "/root/.ICEauthority"

# --- Scenario 7: chrome browser-extension disable ---
# Every launch must inject --no-chrome immediately after the -- terminator,
# and any user-supplied --chrome must be stripped so it can't override
# the injection. The browser-extension native-messaging-host RPC channel
# is outside the threat model.
assert_pair scenario7-default "$ARGV1" "/root/.local/bin/claude" "--no-chrome"

# User passes --chrome — it must be filtered out, --no-chrome stays.
ARGV7="$(HOME=/root CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    bwrap_argv_build /workspaces/foo /test/.local/bin/claude --chrome --version)"
assert_contains scenario7-strip "$ARGV7" "--no-chrome"
assert_not_contains scenario7-strip "$ARGV7" "--chrome"
# User's legit args still pass through.
assert_contains scenario7-strip "$ARGV7" "--version"

# --- Scenario 8: resolve_workspace_root ---
# Pure function: priority is env override > /workspaces auto-detect > $PWD.
unset CLAUDE_SANDBOX_WORKSPACE_ROOT

# Default: $PWD — no auto-promotion to /workspaces.
assert_eq scenario8-pwd-direct "/workspaces/claude-sandbox2" \
    "$(resolve_workspace_root /workspaces/claude-sandbox2)"

assert_eq scenario8-pwd-nested "/workspaces/claude-sandbox2/sub/deeper" \
    "$(resolve_workspace_root /workspaces/claude-sandbox2/sub/deeper)"

# $PWD outside /workspaces/ → $PWD itself.
assert_eq scenario8-fallback-tmp "/tmp/myproject" \
    "$(resolve_workspace_root /tmp/myproject)"

# $PWD is /workspaces itself → /workspaces (coincidentally same as $PWD).
assert_eq scenario8-edge-bare "/workspaces" \
    "$(resolve_workspace_root /workspaces)"

# Override: CLAUDE_SANDBOX_WORKSPACE_ROOT wins regardless of $PWD.
assert_eq scenario8-override-custom "/srv/custom" \
    "$(CLAUDE_SANDBOX_WORKSPACE_ROOT=/srv/custom resolve_workspace_root /workspaces/foo)"

assert_eq scenario8-override-from-tmp "/srv/custom" \
    "$(CLAUDE_SANDBOX_WORKSPACE_ROOT=/srv/custom resolve_workspace_root /tmp/bar)"

# Migration knob: set to /workspaces to restore the old broad bind.
assert_eq scenario8-restore-broad "/workspaces" \
    "$(CLAUDE_SANDBOX_WORKSPACE_ROOT=/workspaces resolve_workspace_root /workspaces/foo)"

# Empty override treated as unset — falls back to $PWD.
assert_eq scenario8-empty-override "/workspaces/foo" \
    "$(CLAUDE_SANDBOX_WORKSPACE_ROOT= resolve_workspace_root /workspaces/foo)"

assert_eq scenario8-empty-override-fallback "/tmp/bar" \
    "$(CLAUDE_SANDBOX_WORKSPACE_ROOT= resolve_workspace_root /tmp/bar)"

# --- Scenario 8b: VIRTUAL_ENV/bin APPENDED to PATH (never prepended) ---
# A venv binary must not be able to shadow `claude` or a system tool
# (Invariant 1), and VIRTUAL_ENV itself is passed through into the
# sandbox. Guards the deliberate uv/venv passthrough.
mkdir -p "$TMPHOME/venv/bin"
ARGV8B="$(HOME="$TMPHOME" VIRTUAL_ENV="$TMPHOME/venv" \
    CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    bwrap_argv_build "$TMPHOME" /test/.local/bin/claude)"
assert_contains scenario8b-venv-appended "$ARGV8B" \
    "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$TMPHOME/.local/bin:$TMPHOME/venv/bin"
assert_pair scenario8b-venv-passthrough "$ARGV8B" '--setenv' 'VIRTUAL_ENV'

# --- Scenario 9: CLAUDE_SANDBOX_NO_FORGE=1 omits forge token dirs ---
# $TMPHOME/.config/gh and glab-cli were created in scenario 4b.
ARGV9="$(HOME="$TMPHOME" CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    CLAUDE_SANDBOX_NO_FORGE=1 \
    bwrap_argv_build "$TMPHOME" /test/.local/bin/claude)"
assert_not_contains scenario9-no-gh   "$ARGV9" "$TMPHOME/.config/gh"
assert_not_contains scenario9-no-glab "$ARGV9" "$TMPHOME/.config/glab-cli"
assert_contains     scenario9-claude  "$ARGV9" "$TMPHOME/.claude"
assert_contains     scenario9-cache   "$ARGV9" "$TMPHOME/.cache"

# --- Scenario 10: CLAUDE_SANDBOX_ALLOW_WRITE adds extra rw bind ---
mkdir -p "$TMPHOME/extra-rw" "$TMPHOME/extra-rw2"
ARGV10a="$(HOME="$TMPHOME" CLAUDE_SANDBOX_ALLOW_WRITE="$TMPHOME/extra-rw" \
    CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    bwrap_argv_build "$TMPHOME" /test/.local/bin/claude)"
assert_contains scenario10-single "$ARGV10a" "$TMPHOME/extra-rw"

ARGV10b="$(HOME="$TMPHOME" \
    CLAUDE_SANDBOX_ALLOW_WRITE="$TMPHOME/extra-rw
$TMPHOME/extra-rw2" \
    CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    bwrap_argv_build "$TMPHOME" /test/.local/bin/claude)"
assert_contains scenario10-multi-a "$ARGV10b" "$TMPHOME/extra-rw"
assert_contains scenario10-multi-b "$ARGV10b" "$TMPHOME/extra-rw2"

# Non-existent allow-write path must NOT appear (silently skipped).
ARGV10c="$(HOME="$TMPHOME" CLAUDE_SANDBOX_ALLOW_WRITE="/nonexistent/path" \
    CLAUDE_SANDBOX_GITCONFIG_PATH=/etc/claude-gitconfig \
    bwrap_argv_build "$TMPHOME" /test/.local/bin/claude)"
assert_not_contains scenario10-absent "$ARGV10c" "/nonexistent/path"

# --- Scenario 11: parse_config (data-driven) ---
# Each case writes a conf fixture, then asserts a predicate in a FRESH
# shadow-sourced bash so parse_config's exports don't leak between cases.
# SHADOW/TMPCONF are exported so the case bodies can reference them; the
# bodies are single-quoted, so there is no \"…\" / \$… escaping (the old
# pain point). egress-jail defaults ON per ADR 0015.
TMPCONF="$(mktemp)"
register_cleanup "$TMPCONF"
export SHADOW TMPCONF

# parse_case NAME CONF BODY — write CONF (\n-expanded) to $TMPCONF, then assert
# BODY exits 0 in a fresh bash that has sourced the shadow.
parse_case() {
    local name="$1" conf="$2" body="$3"
    printf '%b' "$conf" > "$TMPCONF"
    assert_parse "$name" bash -c 'export CLAUDE_SHADOW_SOURCE_ONLY=1; . "$SHADOW"; '"$body"
}

parse_case scenario11-workspace-root 'workspace-root = /custom/root\n' '
    unset CLAUDE_SANDBOX_WORKSPACE_ROOT
    parse_config "$TMPCONF"
    [ "${CLAUDE_SANDBOX_WORKSPACE_ROOT:-}" = "/custom/root" ]
'

parse_case scenario11-no-forge 'no-forge\n' '
    unset CLAUDE_SANDBOX_NO_FORGE
    parse_config "$TMPCONF"
    [ "${CLAUDE_SANDBOX_NO_FORGE:-}" = "1" ]
'

parse_case scenario11-allow-write-single 'allow-write = /some/path\n' '
    unset CLAUDE_SANDBOX_ALLOW_WRITE
    parse_config "$TMPCONF"
    [ "${CLAUDE_SANDBOX_ALLOW_WRITE:-}" = "/some/path" ]
'

parse_case scenario11-allow-write-multi 'allow-write = /path/one\nallow-write = /path/two\n' '
    unset CLAUDE_SANDBOX_ALLOW_WRITE
    parse_config "$TMPCONF"
    printf "%s\n" "$CLAUDE_SANDBOX_ALLOW_WRITE" | grep -qxF "/path/one" &&
    printf "%s\n" "$CLAUDE_SANDBOX_ALLOW_WRITE" | grep -qxF "/path/two"
'

# egress-jail ON by default (ADR 0015): absent from conf + unset env => enabled
parse_case scenario11-egress-jail-default-on 'no-forge\n' '
    unset CLAUDE_SANDBOX_EGRESS_JAIL
    parse_config "$TMPCONF"
    egress_jail_enabled
'

# a bare `egress-jail` key reaffirms on
parse_case scenario11-egress-jail-bare 'egress-jail\n' '
    unset CLAUDE_SANDBOX_EGRESS_JAIL
    parse_config "$TMPCONF"
    [ "${CLAUDE_SANDBOX_EGRESS_JAIL:-}" = "1" ] && egress_jail_enabled
'

# `egress-jail = 0` in conf disables the jail
parse_case scenario11-egress-jail-conf-off 'egress-jail = 0\n' '
    unset CLAUDE_SANDBOX_EGRESS_JAIL
    parse_config "$TMPCONF"
    [ "${CLAUDE_SANDBOX_EGRESS_JAIL:-}" = "0" ] && ! egress_jail_enabled
'

# env CLAUDE_SANDBOX_EGRESS_JAIL=0 wins over a bare conf `egress-jail`
parse_case scenario11-egress-jail-env-off-wins 'egress-jail\n' '
    export CLAUDE_SANDBOX_EGRESS_JAIL=0
    parse_config "$TMPCONF"
    [ "$CLAUDE_SANDBOX_EGRESS_JAIL" = "0" ] && ! egress_jail_enabled
'

# the predicate's default-on holds with no conf parsed at all
parse_case scenario11-egress-jail-predicate-default '' '
    unset CLAUDE_SANDBOX_EGRESS_JAIL
    egress_jail_enabled
'

# allow-ip single
parse_case scenario11-allow-ip-single 'allow-ip = 172.23.1.2\n' '
    unset CLAUDE_SANDBOX_ALLOW_IP
    parse_config "$TMPCONF"
    [ "${CLAUDE_SANDBOX_ALLOW_IP:-}" = "172.23.1.2" ]
'

# allow-ip multiple, accumulated newline-separated
parse_case scenario11-allow-ip-multi 'allow-ip = 172.23.1.2\nallow-ip = 10.0.5.6\n' '
    unset CLAUDE_SANDBOX_ALLOW_IP
    parse_config "$TMPCONF"
    printf "%s\n" "$CLAUDE_SANDBOX_ALLOW_IP" | grep -qxF "172.23.1.2" &&
    printf "%s\n" "$CLAUDE_SANDBOX_ALLOW_IP" | grep -qxF "10.0.5.6"
'

# allow-ip with empty value is skipped (no trailing blank entry)
parse_case scenario11-allow-ip-empty 'allow-ip =\n' '
    unset CLAUDE_SANDBOX_ALLOW_IP
    parse_config "$TMPCONF"
    [ -z "${CLAUDE_SANDBOX_ALLOW_IP:-}" ]
'

# comments and blank lines are ignored
parse_case scenario11-comments '# comment\n\nworkspace-root = /from/conf\n# another\n' '
    unset CLAUDE_SANDBOX_WORKSPACE_ROOT
    parse_config "$TMPCONF"
    [ "${CLAUDE_SANDBOX_WORKSPACE_ROOT:-}" = "/from/conf" ]
'

# env var wins over config file value
parse_case scenario11-env-wins 'workspace-root = /from/config\n' '
    export CLAUDE_SANDBOX_WORKSPACE_ROOT=/from/env
    parse_config "$TMPCONF"
    [ "${CLAUDE_SANDBOX_WORKSPACE_ROOT:-}" = "/from/env" ]
'

# absent config file is silently skipped
parse_case scenario11-absent '' '
    unset CLAUDE_SANDBOX_WORKSPACE_ROOT
    parse_config "/nonexistent/claude-sandbox.conf"
    [ -z "${CLAUDE_SANDBOX_WORKSPACE_ROOT:-}" ]
'

finish bwrap_argv.sh
