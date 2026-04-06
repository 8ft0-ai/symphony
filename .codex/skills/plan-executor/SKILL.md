---
name: plan-executor
description:
  Execute an existing implementation plan from markdown plan and checklist
  files, keep the checklist current while coding, and use the checklist as the
  source of truth for completed, remaining, and blocked work. Use when the user
  asks to implement a plan in `plans/...`, follow a checklist, or keep a
  project checklist updated as work lands.
---

# Plan Executor

## Goals

- Turn a written plan into concrete code changes.
- Keep the checklist accurate as implementation progresses.
- Prevent "done on paper, not done in code" drift.

## Inputs

- A plan document, usually in `plans/...`.
- A checklist document paired with the plan.

If the user provides only one file:
- Look for its obvious companion in the same folder.
- If no companion exists and the user asked to maintain a checklist, create one
  only when that is clearly part of the request.

## Core Rules

- Read the plan and checklist before touching code.
- Treat the checklist as the execution ledger and the plan as the design guide.
- Do not mark a checklist item complete until the code change and its relevant
  validation are both done.
- If an item is partially done, leave it unchecked.
- If scope changes materially, update the checklist to reflect the new reality
  instead of keeping stale items.
- Do not silently drop checklist items because the implementation got harder
  than expected.

## Workflow

1. Open the plan and checklist.
2. Identify the next smallest coherent batch of checklist items.
3. Inspect the codebase for the files and tests that batch touches.
4. Implement the batch.
5. Run the narrowest useful validation for that batch first, then broader
   validation if needed.
6. Update the checklist immediately after validation.
7. Repeat until the requested scope is complete or a real blocker is reached.

## Checklist Maintenance

When updating the checklist:

- Flip completed items from `[ ]` to `[x]`.
- Leave future or partial work as `[ ]`.
- Keep the original section structure unless it is actively misleading.
- Add short notes only when they help future continuation turns.

Preferred note pattern:

```md
## Status Notes

- `Add controller tests`: blocked by missing fixture coverage for streamed MCP events.
- `Wire dashboard summary`: deferred until transcript payload shape is stable.
```

Only add `## Status Notes` when there is real continuation context worth
preserving.

## Planning Heuristics

- Start with items that unblock later work.
- Prefer vertical slices over scattering tiny edits across many checklist
  sections.
- If the checklist is too coarse, refine it in-place before implementation so
  future turns can resume cleanly.
- Keep refinements concrete and verifiable.

Good refinement:

```md
- [ ] Add app-server handling for `mcpServer/elicitation/request`.
- [ ] Add dashboard humanization for MCP elicitation failures.
- [ ] Add regression tests for fail-fast MCP elicitation handling.
```

Bad refinement:

```md
- [ ] Fix backend.
- [ ] Do tests.
```

## Validation Discipline

- Prefer the smallest command that can prove the item is complete.
- If tests are unavailable, record what you did verify.
- If validation fails, revert the checklist update before proceeding.

## Execution Notes

- When resuming existing work, trust the checklist less than the code. Reconcile
  drift before making new changes.
- If the repo already has a plan/checklist convention, preserve it.
- If the user asks for implementation from a specific plan folder, keep all
  progress tracking in that folder unless told otherwise.
