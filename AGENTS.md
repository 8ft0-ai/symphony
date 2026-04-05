# Symphony Fork

This repository is maintained as a fork for local fixes while still tracking
`openai/symphony`.

## Branch Roles

- `upstream/main`: canonical upstream history.
- `main`: local mirror branch for upstream. Track `upstream/main`. Do not commit
  directly to it.
- `origin/main`: pushed mirror of `main` on the fork.
- `local/main`: long-lived integration branch for local-only patches.
- `fix/*`: topic branches for local-only fixes. Branch from `local/main`.
- Upstreamable work should branch from `main`, not `local/main`.

## Git Workflow

- Prefer PRs for code changes, even when you are the only reviewer.
- Local-only fixes should target `local/main`.
- Use squash merge into `local/main`.
- Do not merge `local/main` back into `main`.
- Do not open local-only PRs against `main`.
- Only commit directly to `local/main` when the user explicitly asks or when
  handling a time-sensitive local emergency.

## Sync Flow

Use the fork sync flow before starting a new local-only branch or when
refreshing the local patch line:

```bash
git fetch upstream --prune
git switch main
git merge --ff-only upstream/main
git push origin main

git switch local/main
git merge main
```

For local-only feature branches, treat `local/main` as the base branch. If a
branch needs a refresh, merge `local/main` into it rather than `origin/main`.

## Skills

- Use `.codex/skills/fork-sync` for fork maintenance work.
- Use the existing `pull` skill for branch update flows only when the branch's
  intended base is `origin/main`.
