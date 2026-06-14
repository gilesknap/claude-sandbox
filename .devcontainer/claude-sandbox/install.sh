#!/usr/bin/env bash
# claude-sandbox installer (bash-only). Idempotent: re-runs after a
# devcontainer rebuild re-establish container state without disturbing
# workspace edits.
#
# Three configurable seams for tests:
#   INSTALL_PREFIX    (default /)   — root of file placement, so
#                                    tests/smoke.sh can drop everything
#                                    into a tmpdir.
#   INSTALL_WORKSPACE (default $PWD) — workspace whose `.claude/` is the
#                                    rw bind root (still used by the
#                                    shadow); no longer carries the
#                                    integrity guard, which is global.
#   INSTALL_USER_HOME (default $HOME) — home whose user-scope
#                                    `~/.claude/settings.json` gets the
#                                    GLOBAL integrity guard merged in.
#                                    Tests point it at a tmpdir so the
#                                    real ~/.claude is never touched.
#   CLAUDE_SANDBOX_SMOKE=1            skip apt + curl-install-claude.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT is the clone — two levels above .devcontainer/claude-sandbox.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFIX="${INSTALL_PREFIX:-/}"
WORKSPACE="${INSTALL_WORKSPACE:-$PWD}"
USER_HOME="${INSTALL_USER_HOME:-$HOME}"
SMOKE="${CLAUDE_SANDBOX_SMOKE:-0}"

# Resolve a target under $PREFIX. Stripping the leading slash lets us
# compose relative-to-prefix paths cleanly without a `//` between root
# and the absolute path.
prefixed() {
    local abs="$1"
    if [ "$PREFIX" = "/" ]; then
        printf '%s\n' "$abs"
    else
        printf '%s\n' "${PREFIX%/}${abs}"
    fi
}

probe_or_refuse() {
    if [ "$SMOKE" = "1" ]; then
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "claude-sandbox: refusing — Debian/Ubuntu only (no apt-get on PATH)." >&2
        exit 1
    fi
}

apt_install() {
    if [ "$SMOKE" = "1" ]; then
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        bubblewrap just jq curl ca-certificates git nodejs gh
    # glab isn't in every Ubuntu repo; install-try.
    apt-get install -y -qq --no-install-recommends glab 2>/dev/null || true
}

probe_userns_or_refuse() {
    if [ "$SMOKE" = "1" ]; then
        return 0
    fi
    if ! bwrap --ro-bind / / --unshare-user-try --unshare-pid -- /bin/true \
            >/dev/null 2>&1; then
        cat >&2 <<'EOF'
claude-sandbox: refusing — kernel unprivileged user namespaces are
forbidden. The bwrap sandbox cannot start without them.

On Ubuntu 24.04:
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
On rootful Docker with default AppArmor: rebuild the devcontainer
under rootless podman, or relax AppArmor for bwrap.
EOF
        exit 1
    fi
}

# install_claude_binary: fetch the real Claude via the official
# installer, then relocate it to a path that is NOT on the user's
# PATH. The official installer drops the binary at ~/.local/bin/claude
# AND prepends ~/.local/bin to the user's shell rc — meaning plain
# `claude` would resolve past our shadow once a new shell starts. By
# moving the binary to /usr/libexec/claude-sandbox/, ~/.local/bin/
# stays empty and the rc-mutation becomes harmless.
install_claude_binary() {
    if [ "$SMOKE" = "1" ]; then
        return 0
    fi
    local real_dest
    real_dest="$(prefixed /usr/libexec/claude-sandbox/claude)"
    if [ -x "$real_dest" ]; then
        # Idempotent: purge any stale copy a prior curl-install may have
        # left at ~/.local/bin/claude so the shadow remains the only
        # `claude` on the user's PATH.
        rm -f "$HOME/.local/bin/claude"
        return 0
    fi
    curl -fsSL https://claude.ai/install.sh | bash
    if [ ! -x "$HOME/.local/bin/claude" ]; then
        echo "claude-sandbox: official installer did not produce \$HOME/.local/bin/claude" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$real_dest")"
    mv "$HOME/.local/bin/claude" "$real_dest"
}

# install_file: byte-stable copy of src → dst at mode 0755. Refuses
# if src is missing (loud-fail beats a downstream errno). cmp -s
# short-circuits so a re-run is a true no-op when content matches.
install_file() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        echo "claude-sandbox: cannot find $src" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    install -m 0755 "$src" "$dst"
}

# install_file_if_absent: place src at dst (mode 0755) only when dst is
# absent. Used for the user-scope statusline, which we seed on a fresh
# machine but never stomp if the owner already has one — the field is
# likewise set-only-if-absent in wire_user_settings.
install_file_if_absent() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        echo "claude-sandbox: cannot find $src" >&2
        exit 1
    fi
    [ -f "$dst" ] && return 0
    mkdir -p "$(dirname "$dst")"
    install -m 0755 "$src" "$dst"
}

ensure_cred_dirs() {
    mkdir -p "$HOME/.config/gh" "$HOME/.config/glab-cli"
    touch "$HOME/.claude.json"
}

# install_conf: place the clone's claude-sandbox.conf at the host-global
# /etc/claude-sandbox.conf the shadow reads at launch. Re-run on every
# rebuild (via postCreate) so the /etc copy tracks the clone's conf.
# Unlike install_file this is skip-if-absent: a promoted target that
# carries no conf, or a clone without one, simply gets no global config
# (parse_config then no-ops). Mode 0644 — it's data, not an executable.
# cmp -s short-circuits so a re-run with unchanged content is a no-op.
install_conf() {
    local src dst
    src="$REPO_ROOT/.devcontainer/claude-sandbox.conf"
    dst="$(prefixed /etc/claude-sandbox.conf)"
    [ -f "$src" ] || return 0
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    install -m 0644 "$src" "$dst"
}

# link_terminal_config: when /user-terminal-config is mounted (the
# convention used by terminal-config-style devcontainers), symlink
# ~/.claude and ~/.claude.json into it so Claude's settings and OAuth
# state are shared across every devcontainer on the host. Runs before
# install_claude_binary so the destinations are guaranteed-clean; a
# pre-existing destination (this repo's bind mount, or a previous
# install) makes ln a no-op via the -e/-L guards.
link_terminal_config() {
    local shared="${CLAUDE_SHARED_CONFIG:-/user-terminal-config}"
    [ -d "$shared" ] || return 0
    mkdir -p "$shared/.claude"
    [ -e "$shared/.claude.json" ] || : > "$shared/.claude.json"
    [ -e "$HOME/.claude" ]      || [ -L "$HOME/.claude" ]      || ln -s "$shared/.claude"      "$HOME/.claude"
    [ -e "$HOME/.claude.json" ] || [ -L "$HOME/.claude.json" ] || ln -s "$shared/.claude.json" "$HOME/.claude.json"
}

# Command strings stamped into the user-scope settings.json. ABSOLUTE
# ($HOME-rooted, expanded by Claude's shell at hook-launch) so they
# resolve from any cwd — a relative command only works when cwd ==
# project root, which a global guard cannot assume. $HOME is left
# literal so a single settings.json works across every container that
# shares it (all run as root). Mirrors the owner's own statusLine form.
GUARD_DIR_REL=".claude/claude-sandbox"
VERIFY_CMD='bash $HOME/'"$GUARD_DIR_REL"'/sandbox-verify.sh'
GATE_CMD='bash $HOME/'"$GUARD_DIR_REL"'/sandbox-gate.sh'
USER_SL_CMD='bash $HOME/.claude/statusline-command.sh'

# install_user_guard: place the GLOBAL integrity guard scripts at
# absolute paths under ~/.claude so they fire in every cwd (the old
# per-repo .claude/hooks/sandbox-check.sh only guarded folders that had
# a project .claude/ — and a Claude Code self-update that re-creates
# ~/.local/bin/claude silently bypassed it). The statusline is seeded
# only-if-absent so an owner-customised one survives.
install_user_guard() {
    local guard_dir="$USER_HOME/$GUARD_DIR_REL"
    install_file "$SCRIPT_DIR/sandbox-verify.sh" "$guard_dir/sandbox-verify.sh"
    install_file "$SCRIPT_DIR/sandbox-gate.sh"   "$guard_dir/sandbox-gate.sh"
    # Statusline is cosmetic + optional: place it only when the source
    # exists (a promoted target ships the guard scripts but not the
    # statusline) and the dest is absent (never stomp an owner's own).
    local sl_src="$REPO_ROOT/.claude/statusline-command.sh"
    if [ -f "$sl_src" ]; then
        install_file_if_absent "$sl_src" "$USER_HOME/.claude/statusline-command.sh"
    fi
}

# wire_user_settings: idempotent jq merge into the user-scope
# ~/.claude/settings.json — the one settings file the real `claude`
# reads in EVERY folder, even when launched unwrapped past the shadow.
# Adds, only if absent (dedup by command basename):
#   - SessionStart  → sandbox-verify.sh (full battery + loud warn)
#   - UserPromptSubmit → sandbox-gate.sh (lean fail-closed gate)
# Always sets env.DISABLE_AUTOUPDATER=1 + autoUpdates=false (root-cause
# removal: the in-container updater is what re-arms the bypass). Sets
# .statusLine only when absent. All other keys — the owner's own — are
# preserved verbatim. Re-running is byte-stable.
#
# A non-JSON (JSONC) settings.json is WARNED about and skipped rather
# than refused: the shadow + relocated binary are the core protection
# and we must not brick the rest of the install over a global file we
# don't own. Claude itself parses settings.json as strict JSON, so this
# case is largely theoretical.
wire_user_settings() {
    local settings="$USER_HOME/.claude/settings.json"
    mkdir -p "$(dirname "$settings")"

    if [ -f "$settings" ] && ! jq -e . "$settings" >/dev/null 2>&1; then
        cat >&2 <<EOF
claude-sandbox: WARNING — $settings is not valid JSON (JSONC?).
Skipping the GLOBAL integrity-guard merge. Hand-add to "hooks":
  "SessionStart":    [{"hooks":[{"type":"command","command":"$VERIFY_CMD"}]}]
  "UserPromptSubmit":[{"hooks":[{"type":"command","command":"$GATE_CMD"}]}]
and set "env":{"DISABLE_AUTOUPDATER":"1"}, "autoUpdates": false.
EOF
        return 0
    fi

    local input merged tmp sl_present=false
    if [ -f "$settings" ]; then input="$(cat "$settings")"; else input='{}'; fi
    # Only wire .statusLine when the script actually landed — otherwise a
    # promoted target with no statusline source would get a field
    # pointing at a missing file (a broken statusline).
    if [ -f "$USER_HOME/.claude/statusline-command.sh" ]; then sl_present=true; fi

    merged="$(printf '%s' "$input" | jq \
        --arg verify "$VERIFY_CMD" --arg gate "$GATE_CMD" --arg sl "$USER_SL_CMD" \
        --argjson slp "$sl_present" '
        .hooks //= {}
        | .hooks.SessionStart //= []
        | .hooks.UserPromptSubmit //= []
        | .env //= {}
        | .env.DISABLE_AUTOUPDATER = "1"
        | .autoUpdates = false
        | (if (.hooks.SessionStart | any(.[].hooks[]?; (.command // "") | endswith("sandbox-verify.sh")))
             then . else .hooks.SessionStart += [{hooks:[{type:"command",command:$verify}]}] end)
        | (if (.hooks.UserPromptSubmit | any(.[].hooks[]?; (.command // "") | endswith("sandbox-gate.sh")))
             then . else .hooks.UserPromptSubmit += [{hooks:[{type:"command",command:$gate}]}] end)
        | (if ($slp and .statusLine == null) then .statusLine = {type:"command",command:$sl} else . end)
    ')"

    mkdir -p "$(dirname "$settings")"
    tmp="$(mktemp "$settings.XXXXXX")"
    printf '%s\n' "$merged" > "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$settings"
}

main() {
    probe_or_refuse
    # Shadow first: with /usr/local/bin/claude in place before the
    # official installer runs, any `claude` lookup during the rest of
    # install resolves (and bash-hashes) to the shadow path, even if
    # the shadow itself transiently fails because bwrap or the real
    # binary haven't landed yet.
    install_file "$SCRIPT_DIR/claude-shadow" "$(prefixed /usr/local/bin/claude)"
    apt_install
    probe_userns_or_refuse
    link_terminal_config
    install_claude_binary
    ensure_cred_dirs
    install_conf
    # GLOBAL integrity guard: lives in user-scope ~/.claude (after
    # link_terminal_config so it follows the shared-config symlink when
    # present), NOT per-workspace. Fires in every cwd, including folders
    # with no project .claude/.
    install_user_guard
    wire_user_settings

    echo "claude-sandbox: install complete."
    echo "  shadow:      $(prefixed /usr/local/bin/claude)"
    echo "  real claude: $(prefixed /usr/libexec/claude-sandbox/claude)"
    echo "  config:      $(prefixed /etc/claude-sandbox.conf)"
    echo "  guard:       $USER_HOME/$GUARD_DIR_REL/{sandbox-verify,sandbox-gate}.sh (global, user-scope)"
    echo "  settings:    $USER_HOME/.claude/settings.json (SessionStart + UserPromptSubmit + DISABLE_AUTOUPDATER)"
    echo "  workspace:   $WORKSPACE"
    echo "  run \`/verify-sandbox\` inside Claude for the live battery."
}

# Source guard: `promote.sh` re-uses `install_file` (and friends) by
# sourcing this file. The guard keeps main() from auto-running in that
# case.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
