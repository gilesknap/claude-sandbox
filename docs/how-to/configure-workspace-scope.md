# Make extra paths writable

By default the sandbox makes only `$PWD` writable. Sibling projects under
`/workspaces/` are read-only. This recipe covers the two ways to widen
that scope.

## Restore the broad `/workspaces` bind

To make every sibling devcontainer project writable again, set
`CLAUDE_SANDBOX_WORKSPACE_ROOT` in your devcontainer's `remoteEnv`:

```json
// .devcontainer/devcontainer.json → remoteEnv
"CLAUDE_SANDBOX_WORKSPACE_ROOT": "/workspaces"
```

Restart (or rebuild) the devcontainer for the change to take effect.

## Add specific writable paths

For extra writable paths without widening to all of `/workspaces`, add
`allow-write` lines to the sandbox config. Edit it in the clone at
`.devcontainer/claude-sandbox.conf`:

```ini
# .devcontainer/claude-sandbox.conf  (installed to /etc/claude-sandbox.conf)
allow-write = /cache
allow-write = /workspaces/sibling-project
```

One absolute path per line. Blank lines and `#` comments are ignored;
non-existent paths are skipped.

## Applying the change

`install.sh` copies the clone's `.devcontainer/claude-sandbox.conf` to the
host-global `/etc/claude-sandbox.conf`, which the shadow reads at launch.
After editing the conf, either:

- re-run `./install`, or
- rebuild the devcontainer (postCreate re-stamps the conf).

## Why the conf lives in `/etc`, not the workspace

The config is read from `/etc/claude-sandbox.conf` rather than from the
rw-bound workspace so that a compromised in-session Claude cannot rewrite
it to widen the next launch's binds. The clone's
`.devcontainer/claude-sandbox.conf` is the editable source; `/etc` is the
authoritative copy the shadow trusts. See the
[threat model](../explanations/threat-model.md) for why the
workspace itself is not a trusted location.
