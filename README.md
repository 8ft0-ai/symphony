# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## Fork Workflow

If you are using this repository as a fork with local-only fixes, keep four branch roles:

- `upstream/main`: canonical upstream history
- `origin/main`: your fork's mirror of upstream
- `local/main`: long-lived integration branch for fixes you want to carry locally
- `fix/*`: short-lived topic branches for individual local changes

Recommended rules:

- Keep `main` clean. Do not commit directly to it.
- Sync `main` from `upstream/main`, then push that fast-forward to `origin/main`.
- Branch local-only work from `local/main`.
- Branch upstreamable work from `main`.
- Merge finished local fixes back into `local/main` so you have a single branch that represents
  upstream plus your local patch set.
- Prefer PRs for code changes instead of direct commits to `local/main`.
- Target local-only PRs at `local/main`.
- Use squash merge into `local/main`.

Typical sync and branch flow:

```bash
git fetch upstream --prune
git switch main
git merge --ff-only upstream/main
git push origin main

git switch local/main
git merge main

git switch -c fix/<change-name> local/main
```

This fork uses `origin` for your fork and `upstream` for `openai/symphony`.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
