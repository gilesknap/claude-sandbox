# Sandbox a team devcontainer

Make your project's devcontainer bring up the sandbox automatically for
every teammate — without copying any sandbox code into your repo. The
project carries a few lines of `postCreate` wiring; the security-critical
machinery stays in this one auditable repo, at a revision you pin and bump
deliberately.

This is the recommended rollout path for a team. For interactive use
beside your own projects, the sibling-clone flow in
[Getting started](../tutorials/getting-started.md) is simpler.

## 1. Add the postCreate wiring

In your project's `.devcontainer/postCreate.sh` (create it if absent):

```bash
#!/usr/bin/env bash
# Bring up claude-sandbox at a pinned revision. Bumping the pin is a
# deliberate, reviewable act — like any dependency upgrade.
set -euo pipefail

CSBX_REPO="https://github.com/DiamondLightSource/claude-sandbox.git"
CSBX_PIN="3.0.0"           # a release tag, or a full commit SHA
CSBX_DIR="$HOME/claude-sandbox"

if [ ! -d "$CSBX_DIR" ]; then
    git clone --filter=blob:none "$CSBX_REPO" "$CSBX_DIR"
fi
git -C "$CSBX_DIR" fetch --quiet origin "$CSBX_PIN" || true
git -C "$CSBX_DIR" checkout --quiet "$CSBX_PIN"

bash "$CSBX_DIR/install" --here
```

`--here` is what makes the pin authoritative. Run with no flag, `install`
resolves and installs the **newest release tag** instead — right for a
one-off clone, wrong here, where you have just checked out the revision
you intend to run. It will not do that silently: on a clone that is
pinned, on a non-default branch, or locally modified, the flagless form
refuses and tells you to pass `--here`. Passing it makes the intent
explicit and keeps the pin the only thing that decides your version.

The clone lives in the container filesystem, so a rebuild re-creates it at
the pinned revision; the installer is idempotent, so re-runs are cheap and
never re-download Claude. Every teammate also gets the `claude-sandbox`
helper CLI on PATH (`gh-auth`, `glab-auth`, `verify`, `version`).

## 2. Wire it into devcontainer.json

```json
// .devcontainer/devcontainer.json
"postCreateCommand": "bash .devcontainer/postCreate.sh",
"runArgs": ["--device=/dev/net/tun"]
```

(If you already have a `postCreateCommand`, chain the line into it — this
file is JSONC and yours; nothing here edits it for you.)

The `--device=/dev/net/tun` runArg is required by the fail-closed
[network egress jail](network-egress-jail.md); without it `claude`
refuses to launch.

## 3. (Optional) team configuration

`install.sh` stamps the clone's `.devcontainer/claude-sandbox.conf` to the
host-global `/etc/claude-sandbox.conf` (never read from the workspace —
see {ref}`the config invariant <adr-untrusted-workspace>`). To ship team
settings, write them into the clone before running the installer:

```bash
cat > "$CSBX_DIR/.devcontainer/claude-sandbox.conf" <<'EOF'
# Team defaults — see reference/configuration for all keys.
allow-ip = 192.168.1.50    # lab device reachable through the jail
EOF
bash "$CSBX_DIR/install" --here
```

:::{admonition} postCreate runs unjailed
:class: warning

Everything in `postCreate.sh` runs as root at container-create time,
outside the sandbox. Review changes to it — and to the pin — with the
same care as a `Dockerfile` change.
:::

## See also

- [Use the container image](use-the-container-image.md) — the zero-wiring
  alternative when your project has no devcontainer.
- [Run without push access](run-without-push-access.md) — disable forge
  token binds for read/edit-only sessions.
- {ref}`adr-remove-promote` — why the sandbox is referenced at a pin
  instead of copied into your repo (the retired `just promote`).
