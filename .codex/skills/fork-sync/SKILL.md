---
name: fork-sync
description:
  Sync this fork's clean mirror and local integration branch. Use when Codex
  needs to fast-forward `main` from `upstream/main`, push the mirror to
  `origin/main`, and roll those changes into `local/main` before local-only
  feature work.
---

# Fork Sync

## Workflow

1. Record the current branch so you can return to it at the end.
2. Verify the worktree is clean before switching branches.
   - If the current branch has uncommitted tracked changes, stop and ask the
     user whether to commit, stash, or postpone the sync.
3. Confirm the required refs exist:
   - remotes: `origin`, `upstream`
   - branches: `main`, `local/main`
4. Fetch upstream refs:
   - `git fetch upstream --prune`
5. Refresh the clean mirror branch:
   - `git switch main`
   - `git merge --ff-only upstream/main`
6. Publish the clean mirror to the fork:
   - `git push origin main`
7. Refresh the local integration branch:
   - `git switch local/main`
   - `git merge main`
8. If `local/main` is used as a PR base on the fork, publish it:
   - first publish: `git push -u origin local/main`
   - later updates: `git push origin local/main`
9. Return to the starting branch if it still exists and the user is actively
   working there.
10. Summarize what changed:
   - new upstream commit range, if any
   - whether `local/main` changed
   - whether downstream `fix/*` branches should merge `local/main`

## Rules

- Never commit directly to `main` during this flow.
- Never merge `local/main` back into `main`.
- Use merge-based updates for `local/main`; do not rebase published branches.
- Treat `main` as the upstream mirror and `local/main` as the local patch line.

## When To Ask The User

Ask only when there is no safe default:

- The worktree is dirty and switching branches would disrupt in-progress work.
- `main`, `local/main`, `origin`, or `upstream` are missing and cannot be
  inferred safely.
- Pushing to the fork requires approval, authentication, or would create the
  first remote `local/main` branch unexpectedly.
