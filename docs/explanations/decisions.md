# Architectural Decision Records

Architectural decisions are made throughout a project's lifetime. As a way of
keeping track of these decisions, we record them in Architecture Decision
Records (ADRs) listed below.

These ADRs record the *why* behind the sandbox's shape, in the threat model's
own terms. The `claude-sandbox` skill (`.claude/skills/claude-sandbox/SKILL.md`)
is the operational companion: it records the same invariants as *regressions to
refuse* for an agent editing the code.

```{toctree}
:glob: true
:maxdepth: 1

decisions/*
```

For more on ADRs see this [blog by Michael Nygard](http://thinkrelevance.com/blog/2011/11/15/documenting-architecture-decisions).
To add one, copy `decisions/COPYME` to the next free `NNNN-slug.md`.
