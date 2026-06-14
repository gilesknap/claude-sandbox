---
html_theme.sidebar_secondary.remove: true
---

# claude-sandbox

bwrap-isolated Claude Code for Debian/Ubuntu devcontainers (rootless Podman is
the supported runtime; rootless Docker works too). A hostile prompt, file, or
tool result cannot reach your host credentials, IDE bridges, or shell
environment. The protection is launch-time: plain `claude` resolves to a shadow
that wraps the real binary in `bwrap`, and a global integrity guard fails loud
and closed if it is ever launched unwrapped.

## How the documentation is structured

::::{grid} 2
:gutter: 3

:::{grid-item-card} {material-regular}`directions_walk;2em` Tutorials
Guided lessons that take you from nothing to a working sandbox.

```{toctree}
:maxdepth: 2

tutorials
```
:::

:::{grid-item-card} {material-regular}`directions;2em` How-to Guides
Focused recipes for specific tasks you already have in mind.

```{toctree}
:maxdepth: 2

how-to
```
:::

:::{grid-item-card} {material-regular}`info;2em` Reference
Dry, factual lookup: config keys, paths, checks, and flags.

```{toctree}
:maxdepth: 2

reference
```
:::

:::{grid-item-card} {material-regular}`menu_book;2em` Explanations
The why behind the design: threat model and sandbox rationale.

```{toctree}
:maxdepth: 2

explanations
```
:::

::::
