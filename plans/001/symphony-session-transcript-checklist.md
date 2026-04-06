# Symphony Session Transcript Checklist

## Storage and config

- [x] Add `observability.transcripts_enabled` to `lib/symphony_elixir/config/schema.ex`.
- [x] Add `observability.transcripts_root` to `lib/symphony_elixir/config/schema.ex`.
- [x] Add `observability.transcript_recent_events_limit` to `lib/symphony_elixir/config/schema.ex`.
- [x] Add transcript-root resolution helpers tied to the current log-file location.
- [x] Create `lib/symphony_elixir/transcript_store.ex`.
- [x] Define per-issue manifest format.
- [x] Define per-session NDJSON event envelope format.
- [x] Ensure transcript storage lives outside issue workspace cleanup paths.

## Ingestion

- [x] Extend `AgentRunner.codex_message_handler/2` to persist transcript events.
- [x] Keep orchestrator forwarding unchanged while adding transcript persistence.
- [x] Persist `issue_id`, `issue_identifier`, `workspace_path`, and `worker_host` on every event.
- [x] Persist `session_id`, `thread_id`, and `turn_id` when available.
- [x] Record terminal session status on `turn_completed`, `turn_failed`, `turn_cancelled`, and `turn_ended_with_error`.
- [x] Log transcript write failures as warnings only.
- [x] Verify transcript persistence never fails the run.

## API

- [x] Add transcript pointers to `GET /api/v1/state` payload entries.
- [x] Replace placeholder `codex_session_logs: []` in `GET /api/v1/:issue_identifier`.
- [x] Build `recent_events` from transcript storage rather than only in-memory last-event state.
- [x] Add `GET /api/v1/:issue_identifier/transcript`.
- [x] Add `GET /api/v1/sessions/:session_id`.
- [x] Add `GET /api/v1/sessions/:session_id.ndjson`.
- [x] Validate `limit`, `cursor`, and `order` query params.
- [x] Return correct `404` and `400` error shapes for transcript endpoints.
- [x] Order routes so transcript/session endpoints do not collide with `GET /api/v1/:issue_identifier`.

## UI

- [x] Add a `Transcript` link to each dashboard issue row.
- [x] Add a new browser route for `/issues/:issue_identifier`.
- [x] Create `IssueLive` for transcript inspection.
- [x] Render issue summary metadata on the transcript page.
- [x] Render a session selector.
- [x] Render paginated event rows with timestamp, event, method, and summary.
- [x] Render expandable raw payload/details blocks.
- [x] Add links for JSON transcript and NDJSON download.

## Tests

- [x] Add unit tests for transcript root/path resolution.
- [x] Add unit tests for NDJSON append and manifest updates.
- [x] Add unit tests for paginated transcript reads.
- [x] Add unit tests for disabled-transcript behavior.
- [x] Add AgentRunner/AppServer integration tests proving every event is persisted.
- [x] Add tests that transcript failures are non-fatal.
- [x] Add controller tests for transcript JSON endpoints.
- [x] Add controller tests for NDJSON download endpoint.
- [x] Add LiveView tests for dashboard transcript links.
- [x] Add LiveView tests for issue transcript page rendering and session switching.

## Docs and rollout

- [x] Update `README.md` with transcript storage location and endpoint docs.
- [x] Update `SPEC.md` so transcript APIs and `codex_session_logs` are no longer placeholders.
- [x] Document how `--logs-root` affects transcript retention.
- [x] Verify transcripts survive workspace cleanup and terminal-state cleanup.
- [x] Verify existing `/api/v1/state`, `/api/v1/:issue_identifier`, and `/api/v1/refresh` consumers remain compatible.
