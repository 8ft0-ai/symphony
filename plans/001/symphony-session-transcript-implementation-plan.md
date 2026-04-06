# Symphony Session Transcript Implementation Plan

Validated against helper checkout `EXR-21/.symphony@9e89dd9` on 2026-04-05.

## Problem

Current Symphony observability is runtime-summary oriented, not transcript oriented.

What exists today:
- The web surface and JSON API already exist at `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
- The issue payload currently hardcodes `logs.codex_session_logs: []`.
- `recent_events` currently returns only the latest synthesized event.
- The Codex app-server client already receives the full upstream event stream, including raw JSON lines and notification methods.

What is missing:
- Durable storage for full per-session transcripts.
- A stable, scriptable API for enumerating sessions and retrieving transcript events.
- A web UI for inspecting an issue/session transcript in more detail than the dashboard summary.

## Goals

- Persist the full Codex app-server event stream for every Symphony session.
- Preserve transcripts across issue workspace cleanup and terminal-state cleanup.
- Expose stable JSON and NDJSON endpoints that are easy to use with `curl`, `jq`, and scripts.
- Add the smallest useful UI change set: dashboard link-out plus a dedicated issue transcript page.
- Keep all existing endpoints backward compatible.
- Ensure transcript persistence failures never block or fail the agent run.

## Non-goals

- Cross-process or cross-host aggregation across multiple Symphony runtimes.
- Full-text search, filtering by arbitrary payload fields, or analytics on transcript content.
- Retroactive backfill for sessions that ran before this feature ships.
- Replacing the existing dashboard summary with a transcript-first UI.

## Proposed Design

### 1. Canonical persistence model

Add a new module:
- `lib/symphony_elixir/transcript_store.ex`

Responsibilities:
- Resolve the transcript root.
- Append transcript events to per-session NDJSON.
- Maintain a lightweight per-issue session manifest for fast listing.
- Read paginated transcript events for JSON APIs.
- Stream raw NDJSON for download endpoints.

Recommended default root:
- Derive from the current log file location, not the issue workspace.
- Default path: `<logs_root>/log/codex_sessions`
- If `--logs-root` is not supplied, this becomes `<cwd>/log/codex_sessions`

Rationale:
- The existing log file already lives outside the issue workspace and survives workspace removal.
- Transcript retention should follow the operator-selected log location.
- This avoids losing transcripts when issue workspaces are cleaned up.

Recommended file layout:

```text
log/codex_sessions/
  issues/
    EXR-21/
      manifest.json
      thread-abc-turn-1.ndjson
      thread-def-turn-2.ndjson
    EXR-22/
      manifest.json
      thread-ghi-turn-1.ndjson
```

`manifest.json` should be a compact summary document for the issue, for example:

```json
{
  "issue_id": "lin_123",
  "issue_identifier": "EXR-21",
  "sessions": [
    {
      "session_id": "thread-abc-turn-1",
      "thread_id": "thread-abc",
      "turn_id": "turn-1",
      "status": "completed",
      "started_at": "2026-04-05T09:10:11Z",
      "ended_at": "2026-04-05T09:14:02Z",
      "event_count": 412,
      "turn_count": 1,
      "worker_host": null,
      "workspace_path": "/tmp/symphony_workspaces/EXR-21"
    }
  ]
}
```

Each `.ndjson` line should be one transcript event envelope. Recommended shape:

```json
{
  "sequence": 42,
  "ts": "2026-04-05T09:11:33Z",
  "issue_id": "lin_123",
  "issue_identifier": "EXR-21",
  "session_id": "thread-abc-turn-1",
  "thread_id": "thread-abc",
  "turn_id": "turn-1",
  "worker_host": null,
  "workspace_path": "/tmp/symphony_workspaces/EXR-21",
  "event": "notification",
  "method": "item/agentMessage/delta",
  "summary": "agent message streaming: wrote API tests",
  "data": {
    "payload": {"method": "item/agentMessage/delta", "params": {}},
    "raw": "{\"method\":\"item/agentMessage/delta\",...}"
  }
}
```

Notes:
- NDJSON is the canonical persisted format.
- `data` should preserve the emitted Symphony message shape as-is.
- `summary` is derived at write time using the same humanization logic already used by the dashboard.
- `method` may be null for non-protocol events such as `session_started` or `turn_ended_with_error`.

### 2. Configuration changes

Extend `observability` in `lib/symphony_elixir/config/schema.ex` with:
- `transcripts_enabled: boolean = true`
- `transcripts_root: string | nil = nil`
- `transcript_recent_events_limit: integer = 50`

Behavior:
- If `transcripts_enabled` is `false`, transcript writes become a no-op and transcript endpoints return empty data with clear status metadata.
- If `transcripts_root` is null, resolve the default transcript root from the log file path.
- `transcript_recent_events_limit` controls how many events to include in additive summary payloads like `GET /api/v1/:issue_identifier`.

No new top-level workflow section is needed. This should stay under `observability` because it is operational/debugging functionality.

### 3. Capture flow

The best insertion point is `AgentRunner`, not `Codex.AppServer`.

Why:
- `AgentRunner` already has `issue`, `workspace`, and `worker_host` context.
- `AgentRunner.codex_message_handler/2` already fans messages out to the orchestrator.
- This allows transcript persistence without making `Codex.AppServer` file-aware.
- It works the same for local and SSH workers because the stream is still observed centrally.

Change plan:
- Extend `AgentRunner.codex_message_handler/2` so it does two things for every message:
  1. Append the event through `TranscriptStore.append/5`
  2. Forward the event to the orchestrator via the existing `{:codex_worker_update, issue_id, message}` message

Suggested call shape:
- `TranscriptStore.append(issue, workspace_context, message)`

`workspace_context` should include:
- `workspace_path`
- `worker_host`
- `session_id` when known
- `thread_id` and `turn_id` when available

Failure mode:
- Transcript append failures must log a warning and continue.
- They must not fail `AppServer.run_turn/4`, `AgentRunner`, or the orchestrator.

### 4. Session lifecycle and manifest updates

The store should treat these events specially:
- `:session_started`
  - Open or create the session record.
  - Record `session_id`, `thread_id`, `turn_id`, `started_at`, `workspace_path`, `worker_host`.
- `:turn_completed`
  - Mark session status `completed` if this is the terminal event for that turn/session.
  - Record `ended_at`.
- `:turn_failed`
  - Mark session status `failed`.
  - Record `ended_at`.
- `:turn_cancelled`
  - Mark session status `cancelled`.
  - Record `ended_at`.
- `:turn_ended_with_error`
  - Mark session status `error`.
  - Record `ended_at`.
- `:startup_failed`
  - Write an issue-scoped pseudo-session event if no `session_id` exists yet.
  - Do not pretend this is a normal session transcript.

Manifest update strategy:
- Keep `manifest.json` additive and small.
- Update it atomically after each append or terminal event.
- It should be fast to answer “what sessions has this issue had so far?” without scanning every NDJSON file.

### 5. API changes

#### 5.1 Keep existing endpoints backward compatible

Existing endpoints remain:
- `GET /api/v1/state`
- `GET /api/v1/:issue_identifier`
- `POST /api/v1/refresh`

Backward-compatible additions only.

#### 5.2 Extend `GET /api/v1/state`

Add transcript pointers to `running[]` and `retrying[]` entries.

Recommended additive fields:

```json
{
  "issue_identifier": "EXR-21",
  "session_id": "thread-abc-turn-1",
  "transcript_url": "/api/v1/EXR-21/transcript",
  "issue_ui_url": "/issues/EXR-21"
}
```

This keeps the dashboard summary useful for scripts without requiring a second lookup just to discover the transcript route.

#### 5.3 Extend `GET /api/v1/:issue_identifier`

Retain the current response shape and replace the placeholder transcript/log fields.

Recommended new payload shape:

```json
{
  "issue_identifier": "EXR-21",
  "issue_id": "lin_123",
  "status": "running",
  "workspace": {
    "path": "/tmp/symphony_workspaces/EXR-21",
    "host": null
  },
  "attempts": {
    "restart_count": 1,
    "current_retry_attempt": 2
  },
  "running": {
    "session_id": "thread-abc-turn-1",
    "turn_count": 3,
    "state": "In Progress",
    "started_at": "2026-04-05T09:10:11Z",
    "last_event": "notification",
    "last_message": "agent message streaming: wrote API tests",
    "last_event_at": "2026-04-05T09:14:01Z",
    "tokens": {
      "input_tokens": 1200,
      "output_tokens": 800,
      "total_tokens": 2000
    }
  },
  "retry": null,
  "logs": {
    "codex_session_logs": [
      {
        "label": "latest",
        "session_id": "thread-abc-turn-1",
        "path": "/abs/path/log/codex_sessions/issues/EXR-21/thread-abc-turn-1.ndjson",
        "url": "/api/v1/sessions/thread-abc-turn-1.ndjson"
      }
    ]
  },
  "recent_events": [
    {
      "sequence": 409,
      "at": "2026-04-05T09:13:58Z",
      "event": "notification",
      "method": "item/agentMessage/delta",
      "message": "agent message streaming: wrote API tests"
    }
  ],
  "transcript": {
    "available": true,
    "latest_session_id": "thread-abc-turn-1",
    "session_count": 3,
    "url": "/api/v1/EXR-21/transcript",
    "ui_url": "/issues/EXR-21"
  },
  "last_error": null,
  "tracked": {}
}
```

`recent_events` should come from transcript storage, not just the in-memory `last_codex_message` projection.

#### 5.4 New endpoint: `GET /api/v1/:issue_identifier/transcript`

Purpose:
- Primary scriptable JSON endpoint for issue transcript inspection.
- Returns session list plus paginated events for one selected session.

Query params:
- `session_id` optional, defaults to latest session for the issue
- `limit` optional, default `200`, max `1000`
- `cursor` optional, opaque pagination cursor or integer offset
- `order` optional, `asc` or `desc`, default `asc`

Recommended response shape:

```json
{
  "issue_identifier": "EXR-21",
  "issue_id": "lin_123",
  "selected_session_id": "thread-abc-turn-1",
  "sessions": [
    {
      "session_id": "thread-abc-turn-1",
      "thread_id": "thread-abc",
      "turn_id": "turn-1",
      "status": "completed",
      "started_at": "2026-04-05T09:10:11Z",
      "ended_at": "2026-04-05T09:14:02Z",
      "event_count": 412,
      "turn_count": 1,
      "worker_host": null,
      "workspace_path": "/tmp/symphony_workspaces/EXR-21",
      "json_url": "/api/v1/sessions/thread-abc-turn-1",
      "ndjson_url": "/api/v1/sessions/thread-abc-turn-1.ndjson"
    }
  ],
  "events": [
    {
      "sequence": 1,
      "ts": "2026-04-05T09:10:11Z",
      "event": "session_started",
      "method": null,
      "summary": "session started (thread-abc-turn-1)",
      "data": {
        "session_id": "thread-abc-turn-1",
        "thread_id": "thread-abc",
        "turn_id": "turn-1"
      }
    }
  ],
  "pagination": {
    "limit": 200,
    "next_cursor": "200",
    "has_more": true,
    "order": "asc"
  }
}
```

Error behavior:
- `404 issue_not_found` if the issue has no runtime data and no transcript manifest.
- `404 session_not_found` if the issue exists but the supplied `session_id` does not belong to it.
- `400 invalid_pagination` for malformed `limit`, `cursor`, or `order`.

#### 5.5 New endpoint: `GET /api/v1/sessions/:session_id`

Purpose:
- Direct session lookup without first resolving the issue.
- Useful for scripts and for links from the issue manifest.

Query params:
- Same pagination params as above.

Recommended response shape:

```json
{
  "session": {
    "session_id": "thread-abc-turn-1",
    "issue_identifier": "EXR-21",
    "issue_id": "lin_123",
    "status": "completed",
    "started_at": "2026-04-05T09:10:11Z",
    "ended_at": "2026-04-05T09:14:02Z",
    "event_count": 412,
    "worker_host": null,
    "workspace_path": "/tmp/symphony_workspaces/EXR-21",
    "issue_url": "/api/v1/EXR-21",
    "ndjson_url": "/api/v1/sessions/thread-abc-turn-1.ndjson"
  },
  "events": [
    {
      "sequence": 1,
      "ts": "2026-04-05T09:10:11Z",
      "event": "session_started",
      "method": null,
      "summary": "session started (thread-abc-turn-1)",
      "data": {}
    }
  ],
  "pagination": {
    "limit": 200,
    "next_cursor": null,
    "has_more": false,
    "order": "asc"
  }
}
```

#### 5.6 New endpoint: `GET /api/v1/sessions/:session_id.ndjson`

Purpose:
- Raw transcript download/streaming endpoint.
- This is the canonical script-friendly endpoint.

Behavior:
- `Content-Type: application/x-ndjson`
- Returns the persisted NDJSON exactly as stored.
- No pagination.
- `404 session_not_found` if the session is unknown.

Example usage:

```sh
curl -s http://127.0.0.1:4000/api/v1/sessions/thread-abc-turn-1.ndjson | jq .
```

### 6. Minimal UI changes

Keep the existing dashboard. Do not add transcript rendering inline on the main page.

#### 6.1 Dashboard changes

File:
- `lib/symphony_elixir_web/live/dashboard_live.ex`

Minimal change set:
- Add a `Transcript` link alongside the existing `JSON details` link.
- Point it to `/issues/:issue_identifier`.
- Optionally add a small session-count badge if transcript manifest data is already available cheaply.

This is intentionally small. The dashboard remains the summary surface.

#### 6.2 New issue transcript page

Add a new LiveView:
- `lib/symphony_elixir_web/live/issue_live.ex`

Add a new browser route:
- `live "/issues/:issue_identifier", IssueLive, :show`

Minimal page structure:
- Header card with issue identifier, current runtime state, current session, workspace path, worker host.
- Session selector showing all recorded sessions for the issue.
- Transcript event table/list for the selected session.
- Raw JSON details using native `<details>` blocks for each event.
- Links/buttons:
  - `Back to dashboard`
  - `JSON issue details`
  - `JSON transcript`
  - `Download NDJSON`

Event row fields:
- timestamp
- event
- method
- summary
- expandable raw payload/details

Why a separate page instead of an inline dashboard panel:
- Much less risk to the existing summary dashboard.
- No need to overload the running-sessions table layout.
- Cleaner URL that can be bookmarked and shared.
- Easier to extend later with filtering or follow-along features.

### 7. Router and controller changes

Recommended additions:
- Keep `ObservabilityApiController` for now if you want minimal file churn.
- If the controller gets too large, split transcript actions into `TranscriptApiController`.

Router changes:
- Add browser route for `IssueLive` before the catch-all routes.
- Add transcript/session API routes before `get("/api/v1/:issue_identifier", ...)` to avoid route collisions.

Recommended API route order:
- `GET /api/v1/state`
- `POST /api/v1/refresh`
- `GET /api/v1/sessions/:session_id.ndjson`
- `GET /api/v1/sessions/:session_id`
- `GET /api/v1/:issue_identifier/transcript`
- `GET /api/v1/:issue_identifier`

### 8. Presenter changes

File:
- `lib/symphony_elixir_web/presenter.ex`

Responsibilities after the change:
- Keep `state_payload/2` mostly as-is.
- Add transcript URL fields to summary payloads.
- Replace `codex_session_logs: []` placeholder with real transcript log metadata.
- Build `recent_events` from `TranscriptStore.recent_events/2` instead of the current single-entry synthetic payload.

Important constraint:
- `Presenter` should remain a projection layer.
- Transcript reading logic should stay in `TranscriptStore`, not in `Presenter`.

### 9. Backward compatibility

Preserve:
- Existing route paths.
- Existing top-level JSON fields.
- Existing status dashboard behavior.

Only additive changes should be shipped in the first pass.

Specifically:
- `GET /api/v1/state` still returns the same core shape.
- `GET /api/v1/:issue_identifier` still returns the same top-level fields.
- New transcript fields are additive.
- New transcript routes are additive.

### 10. Failure handling

Transcript persistence must be best-effort.

Rules:
- If transcript append fails, log `warning` with `issue_id`, `issue_identifier`, and `session_id` when known.
- Do not interrupt the app-server stream.
- Do not fail the turn.
- Do not block the orchestrator.

Read-side API behavior:
- If transcript storage is unavailable or disabled, return empty transcript/session lists plus explicit status metadata.
- Do not convert transcript read failures into dashboard failures.

### 11. Testing plan

#### Unit tests

Add tests for `TranscriptStore`:
- root resolution from log file and explicit config
- safe path generation
- append creates issue/session files and manifest
- append increments sequence numbers
- list sessions for an issue
- read session events with pagination
- stream NDJSON file
- no-op behavior when transcripts are disabled

#### Agent/app-server integration tests

Add tests proving:
- `AgentRunner` persists every `on_message` event while still forwarding to orchestrator
- `session_started`, `turn_completed`, `turn_failed`, and `turn_ended_with_error` produce correct manifest status
- transcript write failure does not fail the run

#### API/controller tests

Add tests for:
- `GET /api/v1/:issue_identifier/transcript`
- `GET /api/v1/sessions/:session_id`
- `GET /api/v1/sessions/:session_id.ndjson`
- pagination validation
- route ordering and collision prevention
- 404/400 error codes

#### LiveView tests

Add tests for:
- dashboard renders `Transcript` link
- issue transcript page renders session selector and events
- selecting another session updates the rendered event list
- download links and JSON links point to the right routes

### 12. Documentation updates

Update:
- `elixir/README.md`
- if needed, `SPEC.md` sections that currently describe `codex_session_logs` as a placeholder

README additions should cover:
- where transcripts are stored
- how `--logs-root` affects transcript storage
- the new transcript endpoints
- the new issue transcript UI route

### 13. Recommended implementation sequence

#### Phase 1: persistence and APIs
- Add config fields.
- Add `TranscriptStore`.
- Hook transcript append into `AgentRunner`.
- Extend `Presenter` and JSON APIs.
- Add controller and route tests.

#### Phase 2: UI
- Add dashboard transcript links.
- Add `IssueLive` transcript page.
- Add LiveView tests.

#### Phase 3: docs and polish
- Update README and SPEC.
- Verify that logs/transcripts survive workspace cleanup.
- Verify that transcript endpoints remain responsive with several hundred events.

## Exact Files Expected To Change

Existing files:
- `lib/symphony_elixir/agent_runner.ex`
- `lib/symphony_elixir/config.ex`
- `lib/symphony_elixir/config/schema.ex`
- `lib/symphony_elixir_web/router.ex`
- `lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- `lib/symphony_elixir_web/presenter.ex`
- `lib/symphony_elixir_web/live/dashboard_live.ex`
- `README.md`
- `SPEC.md` if the API contract is being kept current in-repo

New files:
- `lib/symphony_elixir/transcript_store.ex`
- `lib/symphony_elixir_web/live/issue_live.ex`
- optionally `lib/symphony_elixir_web/controllers/transcript_api_controller.ex`
- transcript-focused test files under `test/symphony_elixir/`

## Acceptance Criteria

The implementation is done when all of the following are true:
- Every Symphony session produces a durable NDJSON transcript file.
- `GET /api/v1/:issue_identifier/transcript` returns session summaries plus paginated events.
- `GET /api/v1/sessions/:session_id.ndjson` returns raw persisted transcript lines.
- `GET /api/v1/:issue_identifier` no longer hardcodes empty transcript data.
- The dashboard links to a dedicated issue transcript page.
- The issue transcript page lets an operator inspect at least one full session without leaving the browser.
- Transcript write failures are non-fatal.
- Existing `/api/v1/state`, `/api/v1/:issue_identifier`, and `/api/v1/refresh` consumers continue to work.
