:::{admonition} Working in an unpromoted workspace?
:class: tip

Running Claude **unpromoted** is the normal, recommended mode — the shadow and
the global integrity guard protect `claude` in *every* folder, so a workspace
does not need promoting to be safe.

The trade-off is that the `just` recipes and project commands like
`/verify-sandbox` ship **with the claude-sandbox clone**, so they are only
available when Claude's working directory is that clone. To use them, `cd` into
the clone (e.g. `/user-terminal-config/claude-sandbox`), run what you need, then
return to your work — dropping back to the clone like this is expected and fine.
(Promoting the workspace with `just promote` makes them available in place, but
that is optional.)
:::
