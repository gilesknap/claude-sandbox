---
name: pr-review-sweep
description: >
  Work through a pull request's review comments systematically: fan out
  read-only subagents to analyse each comment in parallel, group coupled
  findings, then apply fixes serially with one commit per logical fix and a
  reply + thread-resolve for each. Works for any reviewer — automated bots
  (CodeRabbit, Copilot, etc.) or humans. Use when a PR has many outstanding
  review comments to triage and address, when the user says "walk through the
  review comments", "address the PR comments", or "clear the review on PR #N".
---

# Sweeping a PR's review comments

A disciplined loop for clearing a large set of inline review comments, whatever
their source — an automated reviewer (CodeRabbit, Copilot, Sourcery, …) or a
human. The governing idea:

> **Fan out for analysis (read-only, parallel). Serialize every write.**

Investigation of each comment is independent and read-only, so it parallelises
cheaply across subagents. Editing, committing, replying and resolving touch
shared mutable state (the git index, the working tree, the PR threads) and the
user's approval, so they stay in the main agent, one at a time.

## Why writes are NOT delegated to subagents

- **The git index is shared state.** Concurrent `git add` / `git commit` from
  parallel agents interleave and produce dirty or wrong commits. You cannot get
  "one clean commit per fix" out of a race.
- **Comments cluster.** Deleting one file can resolve many comments; two
  comments can live in one file. Only the main agent, holding *all* verdicts at
  once, can group coupled findings into a single sensible commit.
- **There is an approval gate.** The user decides what gets fixed, skipped, or
  deferred — after seeing the whole picture, not per-worker.

## The loop

### 1. Collect the open threads

Pull the unresolved review threads and their top-level comments. Reply comments
and already-resolved threads are noise — filter them out. By default, gather
**all** unresolved threads; if the user only cares about one reviewer (e.g. a
bot), filter by author login.

```bash
# Top-level comments (path, line, author, title) — the work list.
# Drop the `select(... login ...)` line to include every reviewer, or change
# the pattern to target a specific bot/human (e.g. "coderabbit", "copilot").
gh api repos/<owner>/<repo>/pulls/<N>/comments --paginate \
  | jq -r '.[]
      | select(.in_reply_to_id == null)
      | select(.user.login | test("<reviewer>"; "i"))   # optional filter
      | "id:\(.id)\t\(.user.login)\t\(.path):\(.line // .original_line)\t\(.body | split("\n")[2])"'
```

```bash
# Thread IDs + resolved state (needed later to resolve), keyed by first comment:
gh api graphql -f query='
query($owner:String!,$repo:String!,$n:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$n){
      reviewThreads(first:100){
        nodes{ id isResolved
          comments(first:1){ nodes{ databaseId author{login} path line } } } } } } }' \
  -f owner=<owner> -f repo=<repo> -F n=<N> \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved | not)
        | "\(.id)\t\(.comments.nodes[0].databaseId)\t\(.comments.nodes[0].path)"'
```

Build a numbered table: `# | comment-id | thread-id | path:line | author | one-line title`.
Present it to the user so the scope is visible up front.

### 2. Fan out analysis — one read-only subagent per comment

Spawn `Explore` (or `general-purpose` restricted to reading) subagents, **in a
single message** so they run concurrently. Each gets one comment's full body
(`gh api .../comments/<id> --jq .body`) plus the file path. For same-file
clusters you may hand one agent several comments to save tokens.

Instruct each subagent to return a compact, structured verdict — *not* a file
dump:

- **verdict**: `valid` (real, fix it) / `moot` (already fixed, outdated line, or
  no longer present at HEAD) / `needs-decision` (a judgement call for the user) /
  `wontfix` (disagree, with reason).
- **draft**: the minimal diff or exact change to make (or "delete file X").
- **coupling**: other comment numbers this overlaps with or is resolved by.
- **confidence** + a one-line justification, **verified against current HEAD**
  (review comments go stale — always re-check the live code, not the diff
  snapshot the comment was written against).

The subagent must NOT edit, stage, or commit anything. Its final message is the
verdict; that is all the main agent keeps.

### 3. Synthesize and group

With every verdict in hand, the main agent:

- **Dedups / clusters** coupled findings. Call out one-shot resolutions
  ("removing `foo.patch` resolves #13–16").
- Orders into **logical commits** — one commit per coherent fix, even if it
  closes several comments.
- Flags `needs-decision` items for the user with a concrete recommendation.

Present this plan and **wait for approval** before touching anything. Honour the
standing rule: don't fix or commit without the user asking this turn.

### 4. Apply serially

For each approved group, in order:

1. Make the edits.
2. Quick-validate where cheap (lint the file, run the one relevant test, re-grep
   to confirm the change, etc.). Don't claim a fix works if you didn't check it.
3. Commit — one commit per logical fix. End the message with whatever
   `Co-Authored-By` / sign-off trailer the project uses. Capture the short SHA.

Never run two edit/commit cycles concurrently.

### 5. Reply and resolve each thread

After the fix is committed, for every comment it closed:

```bash
gh api repos/<owner>/<repo>/pulls/<N>/comments/<comment-id>/replies \
  -f body="Fixed in <sha> — <one line on what changed>."
```

```bash
gh api graphql -f query='mutation($t:ID!){
  resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' \
  -f t=<thread-id> --jq '.data.resolveReviewThread.thread.isResolved'
```

Reply *before* resolving, and only resolve once the fix is actually committed.
For `moot` verdicts, reply explaining why (already fixed in <sha> / line no
longer present) and resolve. For `wontfix`, reply with the reasoning and leave
the thread for the user (or the reviewer) to resolve or rebut — don't
unilaterally close a human's comment you disagreed with.

### 6. Report and push

Finish with a table: each comment → `fixed <sha>` / `moot` / `deferred` /
`wontfix`. Push at the end (not per-commit) unless the user wants otherwise:

```bash
GIT_CONFIG_GLOBAL=/dev/null git -c credential.helper='!gh auth git-credential' \
  push https://github.com/<owner>/<repo>.git <branch>
```

Use HTTPS + gh's credential helper — never SSH, never a PAT in the URL.

## Guardrails

- **Verify every finding against current code.** Comments reference a diff
  snapshot and go stale; a "fix" against an outdated line is worse than nothing.
- **Writes are serial and main-agent-only.** Subagents analyse; they never edit
  or commit.
- **One commit per logical fix**, grouping coupled comments — not one commit per
  comment when they share a root cause.
- **Approval gate** before applying. Recommend, don't auto-apply.
- **Reply cites the commit SHA**; resolve only after the commit exists.
- **Don't unilaterally close human comments** you marked `wontfix` — leave those
  for the author. Auto-resolving is fine for findings you actually fixed.
- For a very large PR you can run the step-2 fan-out as a `Workflow`
  (pipeline: analyse → the main agent still applies serially), but only if the
  user has opted into workflow orchestration.
