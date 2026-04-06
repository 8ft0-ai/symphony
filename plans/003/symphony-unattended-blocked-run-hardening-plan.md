# Symphony Unattended Blocked Run Hardening Plan

Validated against the live `EXR-21` Symphony runtime on 2026-04-06.

This plan builds on the behavior already introduced by the MCP elicitation fast-fail work:
- `mcpServer/elicitation/request` is already detected and returned as `{:error, {:mcp_elicitation_required, payload}}`.
- The remaining production bug is that Symphony still treats that outcome as a generic worker failure and retries it, and it has no structured way for a normal Codex turn to say "I am blocked; do not continue this active issue automatically."

## Problem

Symphony currently has two separate unattended-loop failure modes:

1. Known interactive blockers become generic retries.
   - `Codex.AppServer` correctly fails fast on MCP elicitation.
   - `AgentRunner` raises on that known blocked result.
   - `Orchestrator` sees only an abnormal task exit and schedules a retry.
   - Result: a fast crash-and-retry loop instead of a visible blocked state.

2. Normal blocked conclusions become continuation loops.
   - A Codex turn can finish normally after determining that progress is impossible in the current environment.
   - If the Linear issue remains in an active state, `Orchestrator` treats the normal exit as "continue working."
   - Result: a new turn starts even though the previous turn already established a real blocker.

The `EXR-21` incident hit both modes:
- The issue had already been left active in `In Review` without an issue-scoped PR.
- The workspace could not safely complete Git publish steps from inside the Codex runtime.
- A follow-up turn tried to repair the inconsistent Linear state by moving the issue back to `In Progress`.
- Linear required approval for that mutation.
- Symphony retried the issue instead of preserving the blocked condition.

## Why Current Behavior Happens

### 1. App-server correctly classifies the interactive blocker

`elixir/lib/symphony_elixir/codex/app_server.ex` already treats `mcpServer/elicitation/request` as a dedicated blocked condition instead of a generic notification.

That is the correct lower-level behavior and should be preserved.

### 2. AgentRunner collapses all non-`:ok` outcomes into exceptions

`elixir/lib/symphony_elixir/agent_runner.ex` currently raises for every `{:error, reason}` returned from the run path.

That means Symphony throws away the semantic difference between:
- a known, non-retryable unattended blocker,
- a retryable runtime failure,
- and an unexpected crash.

### 3. Orchestrator only knows `:normal` vs "everything else"

`elixir/lib/symphony_elixir/orchestrator.ex` uses `Task` `:DOWN` messages as the main worker outcome signal.

Current logic:
- `:normal` -> continuation check if issue is still active.
- anything else -> retry with backoff.

There is no first-class blocked outcome, no suppression state, and no fingerprint that says "do not redispatch this active issue until something external changes."

### 4. Prompt/workflow contract is missing a structured blocker signal

The current workflow prompt says:
- unattended sessions must not ask humans for follow-up,
- stop only on true blockers,
- keep going while the issue remains active.

But Symphony does not give the agent a structured, first-party way to report:
- `blocked`,
- `blocked_reason`,
- `retryable? false`,
- `clear_when`.

So the only machine-readable blocker paths are the ones the wrapper happens to infer from transport-level events.

### 5. `In Review` is treated as active without guaranteed review readiness

The service-request-portal workflow lists `In Review` as an active state, but the same prompt also assumes `In Review` means a PR is attached and validated.

Those are not equivalent.

When that invariant is false, Symphony still dispatches the issue into an unattended turn, which encourages corrective behavior inside the turn instead of rejecting the bad state before dispatch.

### 6. Git metadata capability is ambiguous from inside Codex

At the host filesystem level, the workspace `.git` directory may be writable by the user.
Inside the Codex runtime, Git metadata writes can still be blocked by sandbox behavior or policy.

Symphony currently records that symptom in the workpad, but it does not elevate it into a structured blocked condition that the orchestrator can honor.

## Scope

In scope:
- Add a first-class blocked run outcome to Symphony.
- Distinguish non-retryable unattended blockers from retryable failures.
- Prevent automatic redispatch of active issues whose last run ended in a blocked disposition.
- Give Codex a structured way to report blocked/completed dispositions intentionally.
- Preserve current MCP elicitation fast-fail behavior while wiring it into the new disposition flow.
- Add dispatch-time hardening for review-state invariants.
- Improve dashboard/API/log visibility for blocked states and clearance conditions.
- Add regression coverage for retry suppression and blocked redispatch rules.

Out of scope:
- Changing Codex sandbox internals or assuming Codex will permit `.git` writes.
- Auto-approving arbitrary MCP elicitation prompts.
- Rewriting all downstream `WORKFLOW.md` files in the same patch.
- Solving every GitHub or Linear auth problem through automatic recovery.
- Replacing the current app-server or task-supervisor model.

## Goals

- Known unattended blockers must not be retried as generic crashes.
- A normal Codex turn must be able to say "blocked" in a machine-readable way.
- Active issues with unchanged blocked conditions must not redispatch on the next poll.
- `In Review` issues should only dispatch into active unattended work when the workflow invariant for review readiness is satisfied.
- Operators should see the exact blocked reason and what changed will clear it.
- Transient failures and real stalls should still retry.

## Non-goals

- Inferring blocked state from final-answer prose.
- Matching `RuntimeError` strings to classify failures.
- Making `In Review` passive for every workflow by hardcoded default.
- Introducing a broad policy engine for every possible external dependency.

## Proposed Design

### 1. Introduce a first-class run disposition model

Add a small internal disposition model that survives beyond the app-server boundary.

Recommended shape:
- `{:completed, metadata}`
- `{:blocked, reason, metadata}`
- `{:failed, reason, metadata}`

Minimum metadata:
- `summary`
- `retryable?`
- `reason_code`
- `clearance_hint`
- `details`

Rationale:
- `AppServer` already knows about transport-level blockers.
- Codex sometimes discovers semantic blockers that are not transport failures.
- `Orchestrator` needs a structured signal, not an exception string or issue state guess.

### 2. Add an explicit agent-to-orchestrator disposition channel

Do not rely on `Task` exit reasons alone.

Recommended implementation:
- `AgentRunner` sends a dedicated message to the orchestrator recipient before exit, for example:
  - `{:agent_run_disposition, issue_id, disposition}`
- `Orchestrator` stores that disposition in the running entry before the task exits.

Why this is preferable:
- `Task` return values are not available through the current `Task.Supervisor.start_child/2` pattern.
- `:DOWN` only tells us `:normal` vs crash.
- The orchestrator already receives worker-side messages, so this fits the current architecture.

### 3. Preserve existing app-server blocker detection but stop converting it into a generic crash

Keep the current `Codex.AppServer` behavior for:
- `{:error, {:mcp_elicitation_required, payload}}`
- `{:error, {:approval_required, payload}}`
- `{:error, {:turn_input_required, payload}}`

Change `AgentRunner` handling so known unattended blockers:
- emit a blocked disposition,
- return normally,
- and do not raise.

Unexpected runtime failures should still raise or surface as retryable failures.

Recommended classification table:
- `:mcp_elicitation_required` -> blocked, non-retryable
- `:approval_required` -> blocked, non-retryable
- `:turn_input_required` -> blocked, non-retryable
- `:turn_timeout` -> failed, retryable
- `{:port_exit, status}` -> failed, retryable unless explicitly mapped otherwise
- unknown exception -> failed, retryable by current policy

### 4. Give Codex an explicit tool for semantic blocked/completed outcomes

Add a new built-in Symphony dynamic tool, for example:
- `symphony_report_run_outcome`

Suggested input contract:
- `status`: `completed` | `blocked`
- `reason_code`: stable machine code
- `summary`: short human-readable summary
- `retryable`: boolean
- `clearance_hint`: short description of what must change externally
- `details`: optional structured object

This tool should:
- validate the payload strictly,
- emit a worker-side event,
- store the disposition in `AgentRunner`,
- and return a small success payload to Codex.

Why this tool is needed:
- transport-level blockers are only part of the problem,
- normal blocked conclusions also need machine-readable semantics,
- parsing final prose is brittle and untestable.

### 5. Add a small core prompt contract for unattended blocker reporting

Symphony should not depend on every downstream workflow remembering a custom tool name.

Recommended approach:
- prepend or append a small Symphony-owned contract block to every prompt built by `PromptBuilder`,
- state that true unattended blockers must be reported through `symphony_report_run_outcome`,
- state that the final message should follow the tool call, not replace it.

Keep the contract short and stable so it can coexist with downstream prompts.

This avoids:
- workflow drift,
- repo-by-repo prompt edits,
- and blocked loops caused by "the agent knew it was blocked but had no machine-readable way to say so."

### 6. Teach the orchestrator the difference between continuation, blocked, and retry

Extend the running entry with:
- `disposition`
- `blocked_reason`
- `blocked_summary`
- `blocked_at`
- `blocked_clearance_hint`

Update `:DOWN` handling:
- `:normal` + no disposition -> keep current completion path
- `:normal` + `{:completed, ...}` -> treat as normal completion
- `:normal` + `{:blocked, ...}` -> do not schedule continuation or retry
- abnormal exit + explicit blocked disposition -> do not retry
- abnormal exit + explicit failed disposition -> retry according to policy
- abnormal exit + no disposition -> keep current fallback retry

This is the key behavioral fix.

### 7. Persist blocked issues outside `running`

Add a new orchestrator state bucket, for example:
- `blocked: %{issue_id => blocked_entry}`

Each blocked entry should include:
- `identifier`
- `reason_code`
- `summary`
- `blocked_at`
- `issue_state`
- `issue_updated_at`
- `worker_host`
- `workspace_path`
- `clearance_hint`

Update dispatch gating so blocked issues are skipped while their fingerprint is unchanged.

Recommended unblock rule:
- clear the blocked entry when the issue leaves active states, or
- clear it when `updated_at` or `state` changes, or
- clear it on explicit manual refresh/restart if such a control exists.

Reasoning:
- a human or automation can modify the issue/workpad/state to make it worth trying again,
- unchanged active issues should not re-enter the same blocked turn repeatedly.

### 8. Harden active review-state dispatch with explicit invariants

Add a configurable dispatch precondition for review-like active states.

Recommended first-use invariant:
- if state is `In Review` and workflow opts in,
  - require an attached PR or discovered issue-scoped PR before dispatching an active unattended turn.

If the invariant fails:
- mark the issue blocked with a review-state invariant reason,
- do not dispatch a Codex turn,
- expose the reason in the dashboard/API.

Make this configurable rather than hardcoded, because:
- some workflows may use `In Review` without GitHub,
- some workflows may intentionally keep review states active.

Suggested config direction:
- workflow-level review dispatch policy, for example:
  - `tracker.review_dispatch.requires_pr: true`

### 9. Surface Git metadata capability as a structured blocked reason

Do not treat "host FS writable" and "Codex runtime can perform Git metadata writes" as equivalent.

Recommended behavior:
- when the agent determines Git metadata writes required for publish/branch operations are unavailable inside the runtime, it should report:
  - `status=blocked`
  - `reason_code=git_metadata_writes_unavailable`
  - `retryable=false`
  - a clearance hint explaining that the execution environment must change

This should be treated as a real blocked disposition, not a successful completion that happens to mention a blocker in text.

### 10. Improve operator visibility

Extend dashboard/API/logging surfaces so blocked states are obvious.

Add:
- humanized blocked summaries in the status dashboard,
- blocked reason metadata in the issue API response,
- explicit blocked entries in snapshot/state output,
- log lines when an issue is blocked, suppressed, and later unblocked due to issue changes.

The operator should be able to answer:
- why the issue is not running,
- whether it is retrying,
- what external change is needed before it will run again.

### 11. Keep retries narrow and intentional

After this change, retries should remain only for:
- transient transport failures,
- worker crashes,
- port exits,
- timeouts,
- and explicit retryable failures.

They should not happen for:
- MCP elicitation requests,
- command approval prompts in unattended mode,
- turn input requirements,
- workflow invariant failures,
- or explicit blocked outcomes reported by the agent.

## Implementation Notes

Primary files likely to change:
- `elixir/lib/symphony_elixir/codex/app_server.ex`
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/status_dashboard.ex`
- `elixir/lib/symphony_elixir_web/presenter.ex`
- `elixir/lib/symphony_elixir/prompt_builder.ex`

Primary test files likely to change:
- `elixir/test/symphony_elixir/app_server_test.exs`
- `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- `elixir/test/symphony_elixir/core_test.exs`
- `elixir/test/symphony_elixir/extensions_test.exs`

## Recommended Delivery Order

### Phase 1: Disposition plumbing

- Add the disposition model.
- Add the new dynamic tool.
- Add the prompt contract.
- Add `AgentRunner -> Orchestrator` disposition messaging.

### Phase 2: Retry suppression

- Add blocked-state storage in the orchestrator.
- Update `:DOWN` handling to respect blocked dispositions.
- Prevent continuation/retry for known blocked outcomes.
- Clear blocked entries when issue fingerprints change.

### Phase 3: Review-state hardening

- Add configurable `In Review` dispatch preconditions.
- Prevent active dispatch when review-readiness invariants fail.

### Phase 4: Observability and API polish

- Add dashboard/API blocked-state surfacing.
- Improve log lines and recent-event summaries.

### Phase 5: Validation

- Add focused unit/regression tests.
- Reproduce the `EXR-21` failure chain in a controlled test harness.

## Risks

### Risk: suppressing a retry that should have happened

Mitigation:
- only suppress retries for explicit blocked dispositions and known non-retryable blocker codes,
- keep fallback retry behavior for unknown crashes.

### Risk: blocked issues never rerun after a human fixes the state

Mitigation:
- fingerprint blocked entries with issue `updated_at` and `state`,
- clear the blocked entry automatically when the issue changes.

### Risk: prompt contract drift with downstream workflows

Mitigation:
- inject a small Symphony-owned unattended contract centrally,
- keep it additive and narrow,
- do not replace downstream workflow prompts.

### Risk: review-state invariants are too GitHub-specific

Mitigation:
- make review dispatch guards configurable,
- default them conservatively for workflows that opt in.

## Acceptance Criteria

- A known unattended blocker no longer causes an automatic retry loop.
- A normal Codex turn can explicitly report `blocked` and prevent automatic continuation while the issue remains active.
- Blocked issues are visible in operator surfaces with a concrete reason and clearance hint.
- Blocked active issues redispatch only after a relevant external change.
- Existing transient failure retries still work.
- Existing MCP elicitation fast-fail behavior remains intact.
- An `In Review` issue without required review artifacts can be suppressed before dispatch when the workflow enables that guard.

## Open Questions

- Should the new blocked-state bucket appear as a separate dashboard section, or should it be folded into the existing retry/active views?
- Should review dispatch guards ship disabled by default for backward compatibility, or enabled by default for workflows that declare `In Review` as active?
- Do we want a second structured outcome like `waiting` in the future, or is `completed`/`blocked` sufficient for now?

## Explicit Non-goal Follow-up

The downstream service-request-portal workflow should still be reviewed separately.

Recommended follow-up outside this patch:
- reconsider whether `In Review` should remain in `active_states`,
- or explicitly enable the new review-dispatch precondition once available.
