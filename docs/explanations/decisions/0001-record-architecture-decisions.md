# 1. Record architecture decisions

Date: 2026-06-14

## Status

Accepted

## Context

We need to record the architectural decisions made on this project, so a future
reader — human or agent — can see *why* the sandbox is shaped the way it is, not
just *what* it does.

The `claude-sandbox` skill already records operational invariants and the
regressions an agent must refuse. ADRs are the published, user-facing companion:
one decision per record, written in the threat model's own terms.

## Decision

We will use Architecture Decision Records, as [described by Michael Nygard](http://thinkrelevance.com/blog/2011/11/15/documenting-architecture-decisions),
following the python-copier-template layout: records live in
`docs/explanations/decisions/`, numbered `NNNN-slug.md`, each with Status /
Context / Decision / Consequences sections.

## Consequences

See Michael Nygard's article, linked above. To create a new ADR we copy
`COPYME`, give it the next sequential number, and fill in the sections.
