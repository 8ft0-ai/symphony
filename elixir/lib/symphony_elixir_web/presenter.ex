defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  require Logger

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}
  alias SymphonyElixir.TranscriptStore

  @default_transcript_session_limit 100
  @max_transcript_session_limit 500

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case snapshot_issue_entries(issue_identifier, orchestrator, snapshot_timeout_ms) do
      {:ok, running, retry} ->
        {:ok, issue_payload_body(issue_identifier, running, retry)}

      {:error, :issue_not_found} ->
        {:error, :issue_not_found}
    end
  end

  @spec transcript_payload(String.t(), GenServer.name(), timeout(), keyword()) ::
          {:ok, map()} | {:error, :issue_not_found}
  def transcript_payload(issue_identifier, orchestrator, snapshot_timeout_ms, opts \\ [])
      when is_binary(issue_identifier) do
    issue_entries =
      case snapshot_issue_entries(issue_identifier, orchestrator, snapshot_timeout_ms) do
        {:ok, running, retry} -> {running, retry}
        {:error, :issue_not_found} -> {nil, nil}
      end

    running = elem(issue_entries, 0)
    retry = elem(issue_entries, 1)

    with {:ok, sessions} <- TranscriptStore.list_issue_sessions(issue_identifier),
         {:ok, recent_events} <- TranscriptStore.recent_events(issue_identifier) do
      {paged_sessions, sessions_page} = paginate_transcript_sessions(sessions, opts)

      cond do
        TranscriptStore.transcripts_enabled?() == false ->
          transcript_ok(issue_identifier, running, retry, sessions, paged_sessions, sessions_page, recent_events)

        sessions != [] ->
          transcript_ok(issue_identifier, running, retry, sessions, paged_sessions, sessions_page, recent_events)

        not is_nil(running) or not is_nil(retry) ->
          transcript_ok(issue_identifier, running, retry, sessions, paged_sessions, sessions_page, recent_events)

        true ->
          {:error, :issue_not_found}
      end
    else
      {:error, reason} ->
        Logger.warning("Transcript payload read failed issue_identifier=#{issue_identifier}: #{inspect(reason)}")
        {:error, :issue_not_found}
    end
  end

  @spec session_payload(String.t(), keyword()) :: {:ok, map()} | {:error, :session_not_found}
  def session_payload(session_id, opts \\ []) when is_binary(session_id) do
    case TranscriptStore.read_session_events(session_id, opts) do
      {:ok, %{issue_identifier: issue_identifier, session: nil, events: events, page: page}} ->
        {:ok,
         %{
           enabled: TranscriptStore.transcripts_enabled?(),
           issue_identifier: issue_identifier,
           session: nil,
           events: events,
           page: page
         }}

      {:ok, %{issue_identifier: issue_identifier, session: session, events: events, page: page}} ->
        {:ok,
         %{
           enabled: TranscriptStore.transcripts_enabled?(),
           issue_identifier: issue_identifier,
           session: transcript_session_payload(session, issue_identifier, false),
           events: events,
           page: page
         }}

      {:error, :session_not_found} ->
        {:error, :session_not_found}

      {:error, reason} ->
        Logger.warning("Transcript session payload read failed session_id=#{session_id}: #{inspect(reason)}")
        {:error, :session_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    sessions = transcript_sessions(issue_identifier)
    recent_events = transcript_recent_events(issue_identifier)

    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: transcript_log_entries(issue_identifier, sessions)
      },
      recent_events: recent_events,
      transcripts: %{
        enabled: TranscriptStore.transcripts_enabled?(),
        transcript_url: transcript_url(issue_identifier),
        issue_ui_url: issue_ui_url(issue_identifier),
        recent_events_limit: TranscriptStore.recent_events_limit()
      },
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp transcript_payload_body(
         issue_identifier,
         running,
         retry,
         all_sessions,
         sessions,
         sessions_page,
         recent_events
       ) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry) || issue_id_from_sessions(all_sessions),
      status: transcript_status(running, retry, all_sessions),
      enabled: TranscriptStore.transcripts_enabled?(),
      transcript_url: transcript_url(issue_identifier),
      issue_ui_url: issue_ui_url(issue_identifier),
      session_count: length(all_sessions),
      sessions: transcript_session_payloads(sessions, issue_identifier),
      sessions_page: sessions_page,
      recent_events: recent_events
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      transcript_url: transcript_url(entry.identifier),
      issue_ui_url: issue_ui_url(entry.identifier),
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      transcript_url: transcript_url(entry.identifier),
      issue_ui_url: issue_ui_url(entry.identifier),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp transcript_sessions(issue_identifier) do
    case TranscriptStore.list_issue_sessions(issue_identifier) do
      {:ok, sessions} ->
        sessions

      {:error, reason} ->
        Logger.warning("Transcript session listing failed issue_identifier=#{issue_identifier}: #{inspect(reason)}")
        []
    end
  end

  defp transcript_recent_events(issue_identifier) do
    case TranscriptStore.recent_events(issue_identifier) do
      {:ok, events} ->
        Enum.map(events, fn event ->
          %{
            at: event["ts"],
            event: event["event"],
            method: event["method"],
            session_id: event["session_id"],
            message: event["summary"]
          }
        end)

      {:error, reason} ->
        Logger.warning("Transcript recent-event read failed issue_identifier=#{issue_identifier}: #{inspect(reason)}")
        []
    end
  end

  defp transcript_log_entries(issue_identifier, sessions) do
    sessions
    |> transcript_session_payloads(issue_identifier)
    |> Enum.map(fn session ->
      %{
        label: session["label"],
        path: session["path"],
        url: session["ndjson_url"]
      }
    end)
  end

  defp transcript_session_payloads(sessions, issue_identifier) do
    latest_session_id =
      case sessions do
        [%{"session_id" => session_id} | _] -> session_id
        _ -> nil
      end

    Enum.map(sessions, fn session ->
      transcript_session_payload(session, issue_identifier, session["session_id"] == latest_session_id)
    end)
  end

  defp transcript_session_payload(session, issue_identifier, latest?) do
    %{
      "session_id" => session["session_id"],
      "thread_id" => session["thread_id"],
      "turn_id" => session["turn_id"],
      "status" => session["status"],
      "started_at" => session["started_at"],
      "ended_at" => session["ended_at"],
      "event_count" => session["event_count"],
      "worker_host" => session["worker_host"],
      "workspace_path" => session["workspace_path"],
      "last_event" => session["last_event"],
      "last_method" => session["last_method"],
      "last_summary" => session["last_summary"],
      "last_event_at" => session["last_event_at"],
      "label" => if(latest?, do: "latest", else: session["session_id"]),
      "latest" => latest?,
      "path" => TranscriptStore.relative_session_path(issue_identifier, session),
      "url" => session_url(session["session_id"]),
      "ndjson_url" => session_ndjson_url(session["session_id"])
    }
  end

  defp issue_id_from_sessions([%{"session_id" => _} = _session | _] = sessions) do
    sessions
    |> List.first()
    |> Map.get("issue_id")
  end

  defp issue_id_from_sessions(_sessions), do: nil

  defp transcript_status(running, _retry, _sessions) when not is_nil(running), do: "running"
  defp transcript_status(_running, retry, _sessions) when not is_nil(retry), do: "retrying"
  defp transcript_status(_running, _retry, sessions) when sessions != [], do: "completed"
  defp transcript_status(_running, _retry, _sessions), do: "unknown"

  defp transcript_ok(
         issue_identifier,
         running,
         retry,
         all_sessions,
         sessions,
         sessions_page,
         recent_events
       ) do
    {:ok,
     transcript_payload_body(
       issue_identifier,
       running,
       retry,
       all_sessions,
       sessions,
       sessions_page,
       recent_events
     )}
  end

  defp paginate_transcript_sessions(sessions, opts) do
    limit =
      opts
      |> Keyword.get(:session_limit, @default_transcript_session_limit)
      |> normalize_transcript_session_limit()

    cursor =
      opts
      |> Keyword.get(:session_cursor)
      |> normalize_transcript_session_cursor()

    page_sessions =
      sessions
      |> Enum.drop(cursor)
      |> Enum.take(limit)

    has_more = length(sessions) > cursor + length(page_sessions)

    page = %{
      limit: limit,
      cursor: if(cursor == 0, do: nil, else: cursor),
      next_cursor: if(has_more, do: cursor + length(page_sessions), else: nil),
      has_more: has_more
    }

    {page_sessions, page}
  end

  defp normalize_transcript_session_limit(limit) when is_integer(limit) do
    min(max(limit, 1), @max_transcript_session_limit)
  end

  defp normalize_transcript_session_limit(_limit), do: @default_transcript_session_limit

  defp normalize_transcript_session_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: cursor
  defp normalize_transcript_session_cursor(_cursor), do: 0

  defp snapshot_issue_entries(issue_identifier, orchestrator, snapshot_timeout_ms) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, running, retry}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  defp transcript_url(issue_identifier), do: "/api/v1/#{issue_identifier}/transcript"
  defp issue_ui_url(issue_identifier), do: "/issues/#{issue_identifier}"
  defp session_url(session_id), do: "/api/v1/sessions/#{session_id}"
  defp session_ndjson_url(session_id), do: "/api/v1/sessions/#{session_id}.ndjson"

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
