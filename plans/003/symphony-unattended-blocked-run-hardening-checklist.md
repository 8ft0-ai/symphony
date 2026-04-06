# Symphony Unattended Blocked Run Hardening Checklist

## Disposition model

- [x] Add a first-class run disposition model that distinguishes `completed`, `blocked`, and `failed`.
- [x] Define stable blocked reason codes for known unattended blocker classes.
- [x] Carry summary, retryability, and clearance-hint metadata with blocked dispositions.

## App-server and known blocker classification

- [x] Preserve the existing `mcp_elicitation_required` fast-fail behavior.
- [x] Classify `approval_required` as a non-retryable unattended blocker.
- [x] Classify `turn_input_required` as a non-retryable unattended blocker.
- [x] Keep transient failures such as timeouts and unexpected crashes retryable.

## Agent-to-orchestrator signaling

- [x] Add an explicit `AgentRunner -> Orchestrator` disposition message channel.
- [x] Stop raising generic `RuntimeError` for known blocked outcomes.
- [x] Preserve exception-based handling for unexpected failures.
- [x] Record the last reported disposition on the running entry before worker exit.

## Structured blocked reporting from Codex

- [x] Add a new built-in dynamic tool for reporting run outcomes intentionally.
- [x] Validate its input schema strictly.
- [x] Support at least `completed` and `blocked` statuses.
- [x] Allow the agent to report non-retryable blocked reasons such as `git_metadata_writes_unavailable`.

## Prompt contract

- [x] Inject a small Symphony-owned unattended blocker-reporting contract into built prompts.
- [x] Ensure the contract tells the agent to use the run-outcome tool on true blockers.
- [x] Keep the injected guidance additive so downstream workflow prompts still work.

## Orchestrator retry and continuation logic

- [x] Update `:DOWN` handling to distinguish normal completion from blocked completion.
- [x] Prevent retries for explicit blocked dispositions.
- [x] Prevent active-state continuation for explicit blocked dispositions.
- [x] Keep retries for unknown crashes and transient failures.

## Blocked-state persistence

- [x] Add a blocked-issue bucket to orchestrator state.
- [x] Store issue fingerprint data needed to decide when a blocked issue may rerun.
- [x] Skip dispatch for blocked issues while the fingerprint is unchanged.
- [x] Clear blocked entries when the issue leaves active states.
- [x] Clear blocked entries when issue state or `updated_at` changes.

## Review-state dispatch hardening

- [x] Add a configurable precondition for dispatching `In Review` issues.
- [x] Require a review artifact such as an attached or discovered issue-scoped PR when the workflow enables that guard.
- [x] Mark review-state invariant failures as blocked instead of dispatching Codex.
- [x] Keep the guard configurable for non-GitHub workflows.

## Git/sandbox capability surfacing

- [x] Treat Git metadata write unavailability as a structured blocked reason, not only as workpad prose.
- [x] Surface the clearance condition clearly as an environment/runtime constraint.
- [x] Avoid misreporting runtime sandbox limitations as simple filesystem permission problems.

## Observability

- [x] Add dashboard humanization for blocked issue states.
- [x] Expose blocked-state metadata in the observability/API snapshot.
- [x] Log when an issue enters blocked state.
- [x] Log when a blocked issue is released for redispatch because the issue changed.

## Tests

- [x] Add regression coverage for non-retryable MCP elicitation handling end-to-end.
- [x] Add coverage for explicit blocked dispositions reported through the new tool.
- [x] Add coverage that blocked active issues do not continue automatically on normal worker exit.
- [x] Add coverage that blocked issues do not redispatch until their issue fingerprint changes.
- [x] Add coverage that transient failures still retry.
- [x] Add coverage for the review-state precondition guard.
- [x] Add dashboard/API tests for blocked-state visibility.

## Validation

- [ ] Reproduce the current `EXR-21` failure chain in a focused test harness or fixture.
- [x] Verify a known interactive blocker yields blocked state instead of retry.
- [x] Verify a normal semantic blocker yields blocked state instead of active-state continuation.
- [x] Verify an unchanged blocked issue stays suppressed across poll cycles.
- [x] Verify a changed blocked issue becomes dispatchable again.
- [x] Verify operator-visible output shows the blocked reason and clearance hint.

## Rollout and boundaries

- [x] Decide whether review-dispatch preconditions ship enabled or opt-in.
- [x] Document the expected interaction with downstream workflows that keep `In Review` active.
- [x] Record that changing Codex sandbox semantics is outside this patch.

## Status Notes

- `Reproduce the current EXR-21 failure chain in a focused test harness or fixture`: still open; the implemented validation covers the incident modes through focused MCP-blocker, explicit run-outcome, review-guard, and blocked-redispatch tests rather than one monolithic fixture.
- `Review-state dispatch hardening`: ships opt-in via `tracker.review_dispatch.requires_pr`; workflows that keep `In Review` active without issue-scoped PR artifacts should leave the guard disabled until they enforce that invariant.
- `Git/sandbox capability surfacing`: this patch only surfaces runtime Git sandbox limitations as structured blocked dispositions; it does not change Codex sandbox semantics.
