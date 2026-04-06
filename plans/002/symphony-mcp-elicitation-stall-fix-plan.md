# Symphony MCP Elicitation Stall Fix Plan

Validated against the live service-request-portal Symphony runtime on 2026-04-06.

## Problem

Symphony currently lets `mcpServer/elicitation/request` pass through as a generic Codex notification.

Observed effect:
- The Codex turn stops making meaningful progress after an MCP elicitation request.
- The worker remains alive until the workflow-level `stall_timeout_ms` expires.
- The orchestrator then retries the issue after a long idle period.

This is a Symphony bug because the app-server wrapper already treats other interactive prompts as non-interactive blockers:
- `turn/input_required` fails the turn immediately.
- `item/commandExecution/requestApproval` is handled explicitly.
- `item/tool/requestUserInput` is auto-answered or failed immediately.

`mcpServer/elicitation/request` is the missing branch.

## Scope

In scope:
- Make unattended Symphony sessions handle MCP elicitation requests explicitly.
- Prevent 15-minute stall-and-retry behavior for this prompt class.
- Improve dashboard/status messaging so this state is visible and diagnosable.
- Add regression tests around the new handling path.

Out of scope:
- Changing workload-specific `WORKFLOW.md` policy such as keeping `In Review` in `active_states`.
- Rewriting the continuation semantics for review polling in downstream repos.
- Broad MCP auth or token-refresh repair.

## Goals

- Detect MCP elicitation requests as interactive blockers instead of generic notifications.
- Fail fast in unattended runs unless there is a safe, explicit non-interactive answer path.
- Preserve existing behavior for command approvals and tool input prompts.
- Make the dashboard and logs show a useful reason instead of a generic last-event string.

## Non-goals

- Auto-approving arbitrary MCP elicitation prompts without understanding their answer schema.
- Solving external workflow burn caused by `In Review` polling loops.
- Changing default stall timers as the primary mitigation.

## Proposed Design

### 1. Add explicit MCP elicitation handling in `Codex.AppServer`

Update the app-server notification handling so `mcpServer/elicitation/request` no longer falls through the generic `:notification` branch.

Preferred first-pass behavior:
- Recognize `mcpServer/elicitation/request` explicitly.
- Emit a dedicated Symphony event for it.
- Return an immediate non-success result from the turn instead of waiting for stall timeout.

Recommended error shape:
- Introduce a dedicated error tuple such as `{:mcp_elicitation_required, payload}`.

Why a dedicated tuple is better than reusing `:turn_input_required`:
- It preserves the true source of the block.
- It gives the dashboard and logs a specific event to humanize.
- It avoids conflating Codex-native turn prompts with MCP-layer prompts.

### 2. Decide whether auto-answering is safe only after schema inspection

There are two plausible implementations:

Option A:
- Fail fast on every `mcpServer/elicitation/request`.

Option B:
- Auto-answer only when the request matches a known safe schema and the current policy allows a deterministic non-interactive response.

Recommended implementation order:
1. Ship fail-fast handling first.
2. Add auto-answer support only if the payload contract is stable and testable.

Reasoning:
- The immediate production problem is the 15-minute stall.
- Fail-fast removes the stall without inventing MCP decisions.
- Auto-answering unknown prompts is a separate policy question.

### 3. Extend status/dashboard humanization

Add a specific humanized message for the new event so operators see the real cause.

Examples:
- `mcp elicitation requested`
- `mcp elicitation requested: <summary>`
- `turn blocked: waiting for MCP input`

This should surface in:
- status dashboard row summaries
- issue API `last_message`
- recent event summaries

### 4. Keep orchestrator retry semantics unchanged for now

The orchestrator stall watchdog is not the root bug.

Once the app-server fails fast:
- the worker should exit promptly,
- the orchestrator will see an immediate failure path,
- retries can happen quickly and observably instead of after the full stall timeout.

This keeps the first fix narrow and low-risk.

### 5. Add regression coverage

Tests should cover:
- `mcpServer/elicitation/request` causes immediate turn failure.
- the failure happens before `stall_timeout_ms` would matter.
- existing `item/tool/requestUserInput` auto-answer behavior is unchanged.
- existing command/file approval behavior is unchanged.
- dashboard humanization renders the new event clearly.

## Implementation Notes

- Start in `elixir/lib/symphony_elixir/codex/app_server.ex`.
- Add the new event/error handling alongside the existing approval and input-required branches.
- Update any error logging that currently reports only generic session-ended-with-error tuples.
- Extend `elixir/lib/symphony_elixir/status_dashboard.ex` to humanize the new event.
- Add focused tests in `elixir/test/symphony_elixir/app_server_test.exs` and `elixir/test/symphony_elixir/orchestrator_status_test.exs`.

## Workflow Boundary

The `EXR-22` token burn is a separate problem.

It is caused by the downstream service-request-portal workflow configuration and instructions:
- `In Review` is listed as an active state.
- continuation guidance says not to end while the issue remains active.
- review handling explicitly says to keep polling in `In Review`.

This plan does not change that downstream behavior.

If we want to address it later, that should be tracked separately as either:
- a workflow fix in the service-request-portal repo, or
- a new Symphony feature for passive review states / capped unattended review polling.
