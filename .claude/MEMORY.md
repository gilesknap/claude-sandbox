# Project memory

## Branch discipline

**Always check the current branch before making edits.** This repo's feature
branches diverge from `main`, which has gained commits (e.g. the `docs/`
folder, rewritten README) that are not on the feature branch. Starting edits
without rebasing onto `main` first leads to conflicts and stale references.

At the start of any new session:
1. Run `git status` and `git log --oneline -5` to confirm which branch you're on.
2. If not on `main` and not on an intentional feature branch, warn the user.
3. If on a feature branch, check `git log --oneline origin/main..HEAD` to see
   what's ahead, and consider whether a rebase is needed before editing.
