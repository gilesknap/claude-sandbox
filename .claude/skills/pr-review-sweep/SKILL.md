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

**Scope: inline review-thread comments only.** This reads `pulls/N/comments`
(+ their `reviewThreads`) — *not* the PR-level review summary (`pulls/N/reviews`)
or conversation comments (`issues/N/comments`). Bots like CodeRabbit put their
actionable items inline, so those other buckets are usually just summaries — but
a human may leave a real request in the review body, so glance at them manually
before declaring the sweep done.

```bash
# Work list. Drop the login `select` to include everyone, or change the pattern
# (e.g. "coderabbit", "copilot").
gh api repos/<owner>/<repo>/pulls/<N>/comments --paginate \
  | jq -r '.[]
      | select(.in_reply_to_id == null)
      | select(.user.login | test("<reviewer>"; "i"))   # optional filter
      | "id:\(.id)\t\(.user.login)\t\(.path):\(.line // .original_line)\t\((.body | split("\n") | map(select(. != ""))[0]) // "")"'
```

```bash
# Thread IDs + resolved state (needed to resolve later), keyed by first comment.
gh api graphql --paginate -f query='
query($owner:String!,$repo:String!,$n:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$n){
      reviewThreads(first:100, after:$endCursor){
        pageInfo{ hasNextPage endCursor }
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
comments. Don't redo those (a subagent will return `moot`). They aren't on the
PR diff and can't be cited yet — defer their reply+resolve until after the push
(step 6), then cite the now-remote SHA (step 5's pushed-SHA invariant).

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

**The hard gate is the *commit* (stage + `git commit`), not the file write.** A
commit landing without the user speaking between the diff and the commit means
you broke the gate — *even if the fix was right*. Present and commit in **two
separate turns**:

- **Turn A — present, then STOP.** For *this item only*: the proposed change,
  one line why, and the commit message. Present the diff one of two ways:
  - **Describe it** — paste the proposed diff in the message, touch nothing on
    disk. Lightest; fine for small/obvious fixes.
  - **Working-tree preview** — apply the edit to the working tree *uncommitted
    and unstaged*, quick-validate (lint / `bash -n` / one relevant test /
    re-grep), and show the real `git diff`. Use this when the user wants to
    review the change in their own editor/tooling. State plainly that nothing is
    staged or committed and that you'll revert on veto. This is the default once
    the user has asked to review changes on disk.

  Either way: **no `git add`, no `git commit`** — end the turn.
- **Turn B — on an explicit go:** apply the edit if you only described it,
  (re-)validate where cheap — don't claim a fix you didn't check — then stage
  *only this item's files* (never `git add -A`; leave unrelated untracked files
  alone) and commit with the project's sign-off trailer, capture the SHA, and
  present the next item.

A go covers one item; re-present each. On **veto**: if you applied a working-tree
preview, revert it (`git restore <file>` / `git checkout -- <file>`) so a vetoed
item leaves no trace; mark it `deferred` and don't touch later items while
waiting. Only an unprompted, explicit "do them all" lifts the per-item stop.

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
