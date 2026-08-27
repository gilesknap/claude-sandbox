:::{admonition} Working in a different workspace?
:class: tip

The shadow and the global integrity guard protect `claude` in *every*
folder — a workspace needs nothing added to it to be safe, and the
`claude-sandbox` helper commands are on PATH everywhere.

The project command `/verify-sandbox` (the full two-phase audit) ships
**with the claude-sandbox clone**, so it is only available when Claude's
working directory is that clone. Anywhere else, `claude-sandbox verify`
runs the phase-1 battery; for the full audit, `cd` into a clone and run
`/verify-sandbox` there.
:::
