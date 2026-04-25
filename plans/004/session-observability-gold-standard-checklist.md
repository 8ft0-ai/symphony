# Session Observability UX Checklist

## Phase 1: Operator Check-In Baseline

- [x] Add top-level session tabs on `/sessions/:id`:
  - [x] `Check-in` (default)
  - [x] `Debug`
- [x] Keep `Condensed/Raw` controls in `Debug`.
- [x] Add a **Now** card in `Check-in` with:
  - [x] Current phase
  - [x] Last meaningful update
  - [x] Updated ago
  - [x] Health + reason
- [x] Prioritize meaningful narrative in `Check-in`:
  - [x] Project `item/completed` + `agentMessage.text` as `assistant update: ...`
  - [x] Keep milestones and actions readable.
- [x] Hide transport noise in `Check-in`:
  - [x] rate limits
  - [x] token usage
  - [x] startup/status churn
- [x] Condense stream deltas into chunked rows.
- [x] Ensure newest-first default ordering.
- [x] Add/refresh tests for session and issue transcript views.
- [x] Rebuild `bin/symphony` after code changes.

## Phase 2: Actionable Monitoring

- [x] Add “stalled” and “looping” heuristics with explicit warning banners.
- [x] Add per-action duration and result status chips.
- [x] Add a compact “What changed since last check” summary.

## Phase 3: Debuggability and Speed

- [x] Add per-tab URL state presets and keyboard shortcuts.
- [x] Add stronger visual distinction between assistant/action/system/error rows.
- [x] Add optional auto-refresh cadence controls.
