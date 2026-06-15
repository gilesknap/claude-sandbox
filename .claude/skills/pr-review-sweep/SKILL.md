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

A loop for clearing many inline review comments, from any reviewer — bot or
human. Core rule:

> **Fan out for analysis (read-only, parallel). Serialize every write.**
>
> **Every write waits for its own go** — each commit, reply, and resolve is
> approved explicitly, in its own turn. Plan approval and `needs-decision`
> answers don't count.

Analysis of each comment is independent and read-only, so subagents parallelise
it. Edits, commits, replies and resolves touch shared state (git index, working
tree, PR threads) and need user approval, so the **main agent** does them one at
a time. Subagents never edit or commit — concurrent `git` writes race, and only
the main agent, holding every verdict, can group coupled comments into one commit.

## The loop

### 1. Collect open threads

Gather unresolved threads and their top-level comments (skip reply comments and
resolved threads). Default to all reviewers; filter by author login to target one
bot/human.

```bash
# Work list. Drop the login `select` to include everyone, or change the pattern
# (e.g. "coderabbit", "copilot").
gh api repos/<owner>/<repo>/pulls/<N>/comments --paginate \
  | jq -r '.[]
      | select(.in_reply_to_id == null)
      | select(.user.login | test("<reviewer>"; "i"))   # optional filter
      | "id:\(.id)\t\(.user.login)\t\(.path):\(.line // .original_line)\t\(.body | split("\n")[2])"'
```

```bash
# Thread IDs + resolved state (needed to resolve later), keyed by first comment.
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

Build a numbered table (`# | comment-id | thread-id | path:line | author | title`)
and show the user the scope.

**Reconcile local vs remote first** — analysis runs against local HEAD, but PR
threads reflect what's *pushed*:

```bash
git log @{u}..HEAD --oneline   # local commits not yet on the remote
```

Unpushed commits usually mean an interrupted earlier sweep already fixed some
comments. Don't redo those (a subagent will return `moot`) — reply citing the
existing SHA. And they aren't resolved on the PR until pushed (step 5 invariant).

### 2. Fan out analysis — one read-only subagent per comment

Spawn `Explore` agents in a single message (concurrent). Give each one comment
body (`gh api .../comments/<id> --jq .body`) plus the file; hand same-file
clusters to one agent. Each returns a compact verdict, **not** a file dump:

- **verdict**: `valid` / `moot` (already fixed or line gone at HEAD) /
  `needs-decision` (user's call) / `wontfix` (disagree, with reason)
- **draft**: the minimal change (or "delete file X")
- **coupling**: comment #s it overlaps with or resolves
- **confidence** + one line, **verified against current HEAD** (comments go stale)

Subagents never edit. For more than ~10 comments, or when the user wants to
review as they go, launch with `run_in_background: true` and relay each verdict
as it lands; only the step-3 grouping pass needs all verdicts in hand.

### 3. Synthesize and group

Dedup/cluster coupled findings (call out one-shot resolutions, e.g. "removing
`foo.patch` resolves #13–16"), order into logical commits (one per coherent fix,
even if it closes several comments), and flag `needs-decision` items with a
recommendation. Present the plan and wait for approval.

**Plan approval sets the *shape* only — it authorises no edit, commit, or push.**
A `needs-decision` answer ("yes, delete it") settles the *what*, not the go:
still present that item's diff in step 4 and wait. Editing in the same turn a
plan or decision landed means you skipped the gate.

### 4. Apply serially — one explicit go per commit

The commit is a hard gate. Present and commit in **two separate turns**:

- **Turn A — present, then STOP.** For *this item only*: the proposed diff (or
  file list for a deletion), one line why, the commit message. End the turn — no
  edit, no `git add`, no commit yet.
- **Turn B — on an explicit go:** edit, quick-validate where cheap (lint / one
  relevant test / re-grep — don't claim a fix you didn't check), commit with the
  project's sign-off trailer, capture the SHA, then present the next item.

A go covers one item; re-present each. On **veto**: drop it (→ `deferred`) and
don't touch later items while waiting. A commit landing without the user speaking
between diff and commit means you broke the gate — *even if the fix was right*.
Only an unprompted, explicit "do them all" lifts the per-item stop.

### 5. Reply and resolve each thread

```bash
gh api repos/<owner>/<repo>/pulls/<N>/comments/<comment-id>/replies \
  -f body="Fixed in <sha> — <one line on what changed>."

gh api graphql -f query='mutation($t:ID!){
  resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' \
  -f t=<thread-id> --jq '.data.resolveReviewThread.thread.isResolved'
```

Reply before resolving. **Pushed-SHA invariant:** the cited SHA must be on the
remote first, or the reply is a dangling reference and the PR diff lacks the fix.
So if you batch the push to the end (step 6), batch reply+resolve after it too.
For `moot`: reply why (cite the pushed SHA / "line gone") and resolve. For
`wontfix`: reply with reasoning and leave a human's thread for the author to close
— don't unilaterally resolve a comment you disagreed with.

### 6. Report and push

Final table: each comment → `fixed <sha>` / `moot` / `deferred` / `wontfix`.
Push at the end via HTTPS + gh's credential helper (never SSH, never a PAT in the
URL):

```bash
GIT_CONFIG_GLOBAL=/dev/null git -c credential.helper='!gh auth git-credential' \
  push https://github.com/<owner>/<repo>.git <branch>
```
