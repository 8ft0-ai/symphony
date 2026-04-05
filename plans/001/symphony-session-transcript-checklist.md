# Symphony Session Transcript Checklist

## Storage and config

- [ ] Add `observability.transcripts_enabled` to `lib/symphony_elixir/config/schema.ex`.
- [ ] Add `observability.transcripts_root` to `lib/symphony_elixir/config/schema.ex`.
- [ ] Add `observability.transcript_recent_events_limit` to `lib/symphony_elixir/config/schema.ex`.
- [ ] Add transcript-root resolution helpers tied to the current log-file location.
- [ ] Create `lib/symphony_elixir/transcript_store.ex`.
- [ ] Define per-issue manifest format.
- [ ] Define per-session NDJSON event envelope format.
- [ ] Ensure transcript storage lives outside issue workspace cleanup paths.

## Ingestion

- [ ] Extend `AgentRunner.codex_message_handler/2` to persist transcript events.
- [ ] Keep orchestrator forwarding unchanged while adding transcript persistence.
- [ ] Persist `issue_id`, `issue_identifier`, `workspace_path`, and `worker_host` on every event.
- [ ] Persist `session_id`, `thread_id`, and `turn_id` when available.
- [ ] Record terminal session status on `turn_completed`, `turn_failed`, `turn_cancelled`, and `turn_ended_with_error`.
- [ ] Log transcript write failures as warnings only.
- [ ] Verify transcript persistence never fails the run.

## API

- [ ] Add transcript pointers to `GET /api/v1/state` payload entries.
- [ ] Replace placeholder `codex_session_logs: []` in `GET /api/v1/:issue_identifier`.
- [ ] Build `recent_events` from transcript storage rather than only in-memory last-event state.
- [ ] Add `GET /api/v1/:issue_identifier/transcript`.
- [ ] Add `GET /api/v1/sessions/:session_id`.
- [ ] Add `GET /api/v1/sessions/:session_id.ndjson`.
- [ ] Validate `limit`, `cursor`, and `order` query params.
- [ ] Return correct `404` and `400` error shapes for transcript endpoints.
- [ ] Order routes so transcript/session endpoints do not collide with `GET /api/v1/:issue_identifier`.

## UI

- [ ] Add a `Transcript` link to each dashboard issue row.
- [ ] Add a new browser route for `/issues/:issue_identifier`.
- [ ] Create `IssueLive` for transcript inspection.
- [ ] Render issue summary metadata on the transcript page.
- [ ] Render a session selector.
- [ ] Render paginated event rows with timestamp, event, method, and summary.
- [ ] Render expandable raw payload/details blocks.
- [ ] Add links for JSON transcript and NDJSON download.

## Tests

- [ ] Add unit tests for transcript root/path resolution.
- [ ] Add unit tests for NDJSON append and manifest updates.
- [ ] Add unit tests for paginated transcript reads.
- [ ] Add unit tests for disabled-transcript behavior.
- [ ] Add AgentRunner/AppServer integration tests proving every event is persisted.
- [ ] Add tests that transcript failures are non-fatal.
- [ ] Add controller tests for transcript JSON endpoints.
- [ ] Add controller tests for NDJSON download endpoint.
- [ ] Add LiveView tests for dashboard transcript links.
- [ ] Add LiveView tests for issue transcript page rendering and session switching.

## Docs and rollout

- [ ] Update `README.md` with transcript storage location and endpoint docs.
- [ ] Update `SPEC.md` so transcript APIs and `codex_session_logs` are no longer placeholders.
- [ ] Document how `--logs-root` affects transcript retention.
- [ ] Verify transcripts survive workspace cleanup and terminal-state cleanup.
- [ ] Verify existing `/api/v1/state`, `/api/v1/:issue_identifier`, and `/api/v1/refresh` consumers remain compatible.
