# Symphony MCP Elicitation Stall Fix Checklist

## App-server handling

- [x] Add explicit handling for `mcpServer/elicitation/request` in `elixir/lib/symphony_elixir/codex/app_server.ex`.
- [x] Stop treating MCP elicitation requests as generic `:notification` events.
- [x] Emit a dedicated Symphony event for MCP elicitation requests.
- [x] Return an immediate error tuple for unattended MCP elicitation requests.
- [x] Keep existing `turn/input_required` behavior unchanged.
- [x] Keep existing command approval behavior unchanged.
- [x] Keep existing `item/tool/requestUserInput` auto-answer behavior unchanged.

## Error and status surfacing

- [x] Add dashboard/status humanization for the MCP elicitation event in `elixir/lib/symphony_elixir/status_dashboard.ex`.
- [x] Ensure the issue summary shows MCP elicitation as the blocking reason.
- [x] Ensure logs clearly distinguish MCP elicitation from generic turn input prompts.

## Tests

- [x] Add an app-server test that simulates `mcpServer/elicitation/request`.
- [x] Assert the app-server fails fast instead of waiting for stall timeout.
- [x] Add a regression test that existing tool-input auto-answer flows still pass.
- [x] Add a regression test that command approval handling still passes.
- [x] Add a status dashboard test for the new humanized message.

## Validation

- [x] Reproduce the pre-fix behavior with a focused test or fixture.
- [x] Verify the fixed path exits immediately on MCP elicitation.
- [x] Verify no 15-minute stall is required to recover from the prompt.
- [x] Verify operator-visible status text is more specific than `mcpServer/elicitation/request`.

## Docs and boundaries

- [x] Document the new MCP elicitation handling behavior in repo docs or plan notes if needed.
- [x] Record that the `In Review` polling loop is a downstream workflow issue, not part of this patch.
- [x] Keep workflow-level review-loop mitigation out of this branch unless the scope is explicitly expanded.
