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
#   STATUS=1                         force-overwrite the user-scope
#                                    statusline script from the clone's
#                                    copy, instead of seed-only-if-absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT is the clone — two levels above .devcontainer/claude-sandbox.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFIX="${INSTALL_PREFIX:-/}"
WORKSPACE="${INSTALL_WORKSPACE:-$PWD}"
USER_HOME="${INSTALL_USER_HOME:-$HOME}"
SMOKE="${CLAUDE_SANDBOX_SMOKE:-0}"
FORCE_STATUSLINE="${STATUS:-0}"

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
# likewise set-only-if-absent in wire_user_statusline.
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

# _is_mount PATH — true if PATH is itself a mount target. Compares the
# st_dev of PATH against its parent (the heuristic mountpoint(1) uses),
# NOT /proc/mounts: inside the sandbox /proc is the host's procfs
# (--ro-bind /proc /proc), so /proc/mounts shows the host namespace and
# would miss a path the sandbox itself bind-mounted. stat(2) queries the
# live kernel, and unlike mountpoint(1) the st_dev check works for a
# bind-mounted ~/.claude.json (a regular file) too.
_is_mount() {
    local path="$1" pdev ddev
    [ -e "$path" ] || return 1
    pdev="$(stat -c '%d' "$path" 2>/dev/null)" || return 1
    ddev="$(stat -c '%d' "$(dirname "$path")" 2>/dev/null)" || return 1
    [ "$pdev" != "$ddev" ]
}

# _is_empty PATH KIND — true when an existing dir has no entries / a file
# is zero-length. Caller guarantees PATH exists.
_is_empty() {
    local path="$1" kind="$2"
    if [ "$kind" = dir ]; then
        [ -z "$(ls -A "$path" 2>/dev/null)" ]
    else
        [ ! -s "$path" ]
    fi
}

# _ensure_shared SHARED KIND — create an empty shared dir/file when
# absent, so a symlink into it never dangles.
_ensure_shared() {
    local shared="$1" kind="$2"
    if [ -e "$shared" ]; then return 0; fi
    if [ "$kind" = dir ]; then
        mkdir -p "$shared"
    else
        mkdir -p "$(dirname "$shared")"
        : > "$shared"
    fi
}

# _share_path TARGET SHARED KIND — make TARGET ($HOME/.claude{,.json}) a
# symlink into the shared config store, picking the data-preserving
# action for whatever TARGET currently is. The old create-if-absent
# guard silently lost the share whenever TARGET already existed — and in
# a not-yet-promoted devcontainer (install not in postCreate) an
# unsandboxed `claude` or the VS Code extension routinely writes a local
# ~/.claude before install ever runs, permanently shadowing the share.
# Cases:
#   symlink -> SHARED         : nothing to do (idempotent re-run).
#   symlink elsewhere         : repoint to SHARED.
#   active mountpoint         : leave alone — a devcontainer that binds
#                               ~/.claude in directly is already shared,
#                               and a busy mount can't be moved (EBUSY).
#   real, SHARED empty/absent : SEED — move TARGET into SHARED, then
#                               symlink. Preserves a first-run OAuth
#                               token / local history as the new baseline.
#   real, SHARED populated    : shared wins — back TARGET up timestamped,
#                               then symlink (the "adopt" case).
#   absent                    : ensure SHARED exists, then symlink.
_share_path() {
    local target="$1" shared="$2" kind="$3"

    if [ -L "$target" ]; then
        if [ "$(readlink "$target")" = "$shared" ]; then
            return 0
        fi
        _ensure_shared "$shared" "$kind"
        rm -f "$target"
        ln -s "$shared" "$target"
        return 0
    fi

    if _is_mount "$target"; then
        echo "claude-sandbox: $target is an active mountpoint; leaving as-is (assumed already shared)." >&2
        return 0
    fi

    if [ -e "$target" ]; then
        if [ ! -e "$shared" ] || _is_empty "$shared" "$kind"; then
            if [ -e "$shared" ]; then rm -rf "$shared"; fi
            mkdir -p "$(dirname "$shared")"
            mv "$target" "$shared"
            echo "claude-sandbox: seeded shared config $shared from $target." >&2
        else
            local backup="$target.pre-sandbox.$(date +%Y%m%d-%H%M%S)"
            mv "$target" "$backup"
            echo "claude-sandbox: $shared already populated; backed up $target -> $backup." >&2
        fi
        ln -s "$shared" "$target"
        return 0
    fi

    _ensure_shared "$shared" "$kind"
    ln -s "$shared" "$target"
}

# link_terminal_config: when /user-terminal-config is mounted (the
# convention used by terminal-config-style devcontainers), share
# ~/.claude and ~/.claude.json into it so Claude's settings and OAuth
# state follow the user across every devcontainer on the host. Runs
# before install_claude_binary. Delegates per-path policy to
# _share_path, which adopts (or seeds from) a pre-existing local config
# instead of silently leaving it un-shared.
link_terminal_config() {
    local shared="${CLAUDE_SHARED_CONFIG:-/user-terminal-config}"
    [ -d "$shared" ] || return 0
    _share_path "$HOME/.claude"      "$shared/.claude"      dir
    _share_path "$HOME/.claude.json" "$shared/.claude.json" file
}

# The GLOBAL integrity guard is delivered through Claude Code's MANAGED
# settings layer (`/etc/claude-code/managed-settings.json`) — highest
# precedence, and crucially NOT overridable by editing the user's own
# `~/.claude/settings.json`. Two properties make this tamper-resistant
# in the same spirit as Invariant 4 (config at /etc, never the rw
# workspace):
#   - The hook ENTRIES live in /etc — a user editing their shared
#     ~/.claude can't remove them; only root editing /etc (or a
#     deliberate ./install) changes the guard.
#   - The hook SCRIPTS live in /usr/libexec/claude-sandbox (off-PATH,
#     root-owned) — like the relocated real binary, they are ro-bound
#     inside the sandbox (`--ro-bind / /`), so a compromised in-session
#     Claude cannot rewrite them to `exit 0`. (Under ~/.claude they
#     would have been rw-bound and editable.)
# Commands are absolute /usr/libexec paths — no $HOME, resolves in any
# cwd and in both wrapped and unwrapped launches.
GUARD_LIBEXEC="/usr/libexec/claude-sandbox"
VERIFY_PATH="$GUARD_LIBEXEC/sandbox-verify.sh"
GATE_PATH="$GUARD_LIBEXEC/sandbox-gate.sh"
VERIFY_CMD="bash $VERIFY_PATH"
GATE_CMD="bash $GATE_PATH"
MANAGED_SETTINGS="/etc/claude-code/managed-settings.json"
USER_SL_CMD='bash $HOME/.claude/statusline-command.sh'

# install_guard_scripts: place the guard scripts off the user's PATH and
# off the sandbox rw set (same neighbourhood as the relocated real
# binary). Root-owned, ro inside the sandbox.
install_guard_scripts() {
    install_file "$SCRIPT_DIR/sandbox-verify.sh" "$(prefixed "$VERIFY_PATH")"
    install_file "$SCRIPT_DIR/sandbox-gate.sh"   "$(prefixed "$GATE_PATH")"
}

# wire_managed_settings: idempotent jq merge of the guard into the
# managed-settings policy file. Adds (deduped by command basename):
#   - SessionStart    → sandbox-verify.sh (full battery + loud warn)
#   - UserPromptSubmit → sandbox-gate.sh  (lean fail-closed gate)
# and sets env.DISABLE_AUTOUPDATER=1 + autoUpdates=false (root-cause
# removal: the in-container updater is what re-arms the bypass). Foreign
# keys — e.g. a real enterprise admin's org policy — are preserved, so
# we merge rather than own the file. A non-JSON file is warned-and-
# skipped (never brick install over a file we don't exclusively own).
# We deliberately do NOT set allowManagedHooksOnly — that would also
# block the owner's own user/project hooks. Re-running is byte-stable.
wire_managed_settings() {
    local settings; settings="$(prefixed "$MANAGED_SETTINGS")"
    mkdir -p "$(dirname "$settings")"

    if [ -f "$settings" ] && ! jq -e . "$settings" >/dev/null 2>&1; then
        cat >&2 <<EOF
claude-sandbox: WARNING — $settings is not valid JSON.
Skipping the managed integrity-guard merge. Hand-add to "hooks":
  "SessionStart":    [{"hooks":[{"type":"command","command":"$VERIFY_CMD"}]}]
  "UserPromptSubmit":[{"hooks":[{"type":"command","command":"$GATE_CMD"}]}]
and set "env":{"DISABLE_AUTOUPDATER":"1"}, "autoUpdates": false.
EOF
        return 0
    fi

    local input merged tmp
    if [ -f "$settings" ]; then input="$(cat "$settings")"; else input='{}'; fi

    merged="$(printf '%s' "$input" | jq \
        --arg verify "$VERIFY_CMD" --arg gate "$GATE_CMD" '
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
    ')"

    tmp="$(mktemp "$settings.XXXXXX")"
    printf '%s\n' "$merged" > "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$settings"
}

# wire_user_statusline: the user-scope ~/.claude/settings.json now holds
# only the statusline PREFERENCE (set-only-if-absent + script seeded
# only-if-absent — never stomp an owner's own). The integrity guard does
# NOT live here anymore. To migrate an earlier install that DID put the
# guard in user-scope, prune any of our guard-hook entries so the guard
# has a single authoritative home (managed settings) and never double-
# fires. Foreign hooks are preserved. Non-JSON → warn-and-skip.
wire_user_statusline() {
    local settings="$USER_HOME/.claude/settings.json"
    mkdir -p "$(dirname "$settings")"

    local sl_src="$REPO_ROOT/.claude/statusline-command.sh"
    if [ -f "$sl_src" ]; then
        # Seed-only-if-absent by default (never stomp an owner's own);
        # STATUS=1 forces the clone's copy to win (content-compared).
        if [ "$FORCE_STATUSLINE" = "1" ]; then
            install_file "$sl_src" "$USER_HOME/.claude/statusline-command.sh"
        else
            install_file_if_absent "$sl_src" "$USER_HOME/.claude/statusline-command.sh"
        fi
    fi

    if [ -f "$settings" ] && ! jq -e . "$settings" >/dev/null 2>&1; then
        echo "claude-sandbox: WARNING — $settings is not valid JSON; skipping statusline wiring + interim-guard prune." >&2
        return 0
    fi

    local had_file=false input merged tmp sl_present=false
    [ -f "$settings" ] && had_file=true
    if [ "$had_file" = true ]; then input="$(cat "$settings")"; else input='{}'; fi
    if [ -f "$USER_HOME/.claude/statusline-command.sh" ]; then sl_present=true; fi

    merged="$(printf '%s' "$input" | jq \
        --arg sl "$USER_SL_CMD" --argjson slp "$sl_present" '
        (if .hooks.SessionStart    then .hooks.SessionStart    |= map(select((any(.hooks[]?; (.command // "") | endswith("sandbox-verify.sh"))) | not)) else . end)
        | (if .hooks.UserPromptSubmit then .hooks.UserPromptSubmit |= map(select((any(.hooks[]?; (.command // "") | endswith("sandbox-gate.sh"))) | not)) else . end)
        | (if ($slp and .statusLine == null) then .statusLine = {type:"command",command:$sl} else . end)
    ')"

    # Don't create an empty {} settings on a fresh home that has no
    # statusline source to wire (e.g. a promoted target).
    if [ "$had_file" = false ] && printf '%s' "$merged" | jq -e '. == {}' >/dev/null 2>&1; then
        return 0
    fi

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
    # GLOBAL integrity guard via the MANAGED settings layer: scripts off
    # the rw set in /usr/libexec, hook entries + updater-disable in
    # /etc/claude-code/managed-settings.json (highest precedence, not
    # removable by editing ~/.claude). Fires in every cwd. The user-scope
    # settings.json keeps only the statusline preference (and is migrated
    # off any earlier user-scope guard).
    install_guard_scripts
    wire_managed_settings
    wire_user_statusline

    echo "claude-sandbox: install complete."
    echo "  shadow:      $(prefixed /usr/local/bin/claude)"
    echo "  real claude: $(prefixed /usr/libexec/claude-sandbox/claude)"
    echo "  config:      $(prefixed /etc/claude-sandbox.conf)"
    echo "  guard:       $(prefixed "$VERIFY_PATH"), $(prefixed "$GATE_PATH") (off-PATH, ro in sandbox)"
    echo "  managed:     $(prefixed "$MANAGED_SETTINGS") (SessionStart + UserPromptSubmit + DISABLE_AUTOUPDATER)"
    echo "  statusline:  $USER_HOME/.claude/settings.json (preference only)"
    echo "  workspace:   $WORKSPACE"
    echo "  run \`/verify-sandbox\` inside Claude for the live battery."
}

# Source guard: `promote.sh` re-uses `install_file` (and friends) by
# sourcing this file. The guard keeps main() from auto-running in that
# case.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
