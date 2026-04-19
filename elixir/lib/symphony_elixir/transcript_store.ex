defmodule SymphonyElixir.TranscriptStore do
  @moduledoc """
  Persists per-session Codex transcript events outside issue workspaces.
  """

  alias SymphonyElixir.{Config, LogFile, StatusDashboard}
  alias SymphonyElixir.Linear.Issue

  @issues_dir "issues"
  @manifest_filename "manifest.json"
  @default_issue_id "unknown_issue"
  @default_issue_identifier "unknown-issue"
  @default_page_limit 50
  @max_page_limit 500

  @type read_order :: :asc | :desc

  @spec transcripts_enabled?() :: boolean()
  def transcripts_enabled? do
    Config.settings!().observability.transcripts_enabled
  end

  @spec recent_events_limit() :: pos_integer()
  def recent_events_limit do
    Config.settings!().observability.transcript_recent_events_limit
  end

  @spec default_root() :: Path.t()
  def default_root do
    Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
    |> Path.expand()
    |> Path.dirname()
    |> Path.join("codex_sessions")
  end

  @spec root() :: Path.t()
  def root do
    case Config.settings!().observability.transcripts_root do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> default_root()
    end
  end

  @spec issue_directory(String.t()) :: Path.t()
  def issue_directory(issue_identifier) when is_binary(issue_identifier) do
    Path.join([root(), @issues_dir, safe_path_component(issue_identifier)])
  end

  @spec manifest_path(String.t()) :: Path.t()
  def manifest_path(issue_identifier) when is_binary(issue_identifier) do
    Path.join(issue_directory(issue_identifier), @manifest_filename)
  end

  @spec relative_session_path(String.t(), map()) :: Path.t()
  def relative_session_path(issue_identifier, %{"file_name" => file_name})
      when is_binary(issue_identifier) and is_binary(file_name) do
    Path.join([@issues_dir, safe_path_component(issue_identifier), file_name])
  end

  @spec append(Issue.t() | map(), map(), map()) :: :ok | {:error, term()}
  def append(issue, workspace_context, message) when is_map(issue) and is_map(workspace_context) and is_map(message) do
    if transcripts_enabled?() do
      issue_id = issue_id(issue)
      issue_identifier = issue_identifier(issue)
      timestamp = event_timestamp(message)
      session_id = session_id_for(message, workspace_context, timestamp)
      issue_dir = issue_directory(issue_identifier)
      manifest_path = manifest_path(issue_identifier)

      with :ok <- File.mkdir_p(issue_dir),
           {:ok, manifest} <- load_manifest(manifest_path, issue, issue_identifier),
           {session_summary, session_index} <-
             find_or_initialize_session(
               manifest["sessions"],
               session_id,
               message,
               workspace_context,
               timestamp
             ),
           envelope <-
             build_envelope(
               issue_id,
               issue_identifier,
               session_id,
               message,
               workspace_context,
               timestamp,
               session_summary
             ),
           session_file_name <- session_file_name(session_summary),
           session_path <- Path.join(issue_dir, session_file_name),
           :ok <- append_ndjson_line(session_path, envelope),
           updated_session <- update_session_summary(session_summary, envelope),
           updated_manifest <- put_session_summary(manifest, session_index, updated_session) do
        write_json_atomic(manifest_path, updated_manifest)
      end
    else
      :ok
    end
  end

  @spec list_issue_sessions(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_issue_sessions(issue_identifier) when is_binary(issue_identifier) do
    if transcripts_enabled?() do
      with {:ok, manifest} <- load_manifest(manifest_path(issue_identifier), %{}, issue_identifier) do
        {:ok, Enum.sort_by(manifest["sessions"], &sort_key_for_session/1, {:desc, DateTime})}
      end
    else
      {:ok, []}
    end
  end

  @spec recent_events(String.t(), pos_integer() | nil) :: {:ok, [map()]} | {:error, term()}
  def recent_events(issue_identifier, limit \\ nil) when is_binary(issue_identifier) do
    if transcripts_enabled?() do
      event_limit = normalize_limit(limit || recent_events_limit())

      with {:ok, sessions} <- list_issue_sessions(issue_identifier) do
        events = collect_recent_events(issue_identifier, sessions, event_limit)
        finalize_recent_events(events, event_limit)
      end
    else
      {:ok, []}
    end
  end

  @spec get_session(String.t()) :: {:ok, map()} | {:error, :session_not_found | term()}
  def get_session(session_id) when is_binary(session_id) do
    if transcripts_enabled?() do
      find_session(session_id)
    else
      {:error, :session_not_found}
    end
  end

  @spec read_session_events(String.t(), keyword()) :: {:ok, map()} | {:error, :session_not_found | term()}
  def read_session_events(session_id, opts \\ []) when is_binary(session_id) do
    if transcripts_enabled?() do
      limit = normalize_limit(Keyword.get(opts, :limit, @default_page_limit))
      order = normalize_order(Keyword.get(opts, :order, :desc))
      cursor = normalize_cursor(Keyword.get(opts, :cursor))

      with {:ok, %{issue_identifier: issue_identifier, session: session}} <- find_session(session_id),
           {:ok, events} <- read_session_file_events(issue_identifier, session) do
        ordered_events = order_events(events, order)
        filtered_events = apply_cursor(ordered_events, cursor, order)
        page_events = Enum.take(filtered_events, limit)
        has_more? = length(filtered_events) > length(page_events)

        {:ok,
         %{
           session: session,
           issue_identifier: issue_identifier,
           events: page_events,
           page: %{
             limit: limit,
             order: Atom.to_string(order),
             cursor: cursor,
             next_cursor: next_cursor(page_events, has_more?),
             has_more: has_more?
           }
         }}
      end
    else
      {:ok,
       %{
         session: nil,
         issue_identifier: nil,
         events: [],
         page: %{
           limit: normalize_limit(Keyword.get(opts, :limit, @default_page_limit)),
           order: Atom.to_string(normalize_order(Keyword.get(opts, :order, :desc))),
           cursor: normalize_cursor(Keyword.get(opts, :cursor)),
           next_cursor: nil,
           has_more: false
         }
       }}
    end
  end

  @spec read_session_ndjson(String.t()) ::
          {:ok, %{content: binary(), issue_identifier: String.t(), session: map()}}
          | {:error, :session_not_found | term()}
  def read_session_ndjson(session_id) when is_binary(session_id) do
    if transcripts_enabled?() do
      with {:ok, %{issue_identifier: issue_identifier, session: session}} <-
             find_session(session_id),
           session_file <- session_path(issue_identifier, session),
           {:ok, content} <- File.read(session_file) do
        {:ok, %{content: content, issue_identifier: issue_identifier, session: session}}
      end
    else
      {:ok, %{content: "", issue_identifier: nil, session: nil}}
    end
  end

  @spec issue_session_lookup(String.t()) ::
          {:ok, %{issue_identifier: String.t(), session: map()}}
          | {:error, :session_not_found | term()}
  def issue_session_lookup(session_id), do: find_session(session_id)

  @doc false
  @spec session_path(String.t(), map()) :: Path.t()
  def session_path(issue_identifier, %{"file_name" => file_name})
      when is_binary(issue_identifier) and is_binary(file_name) do
    Path.join(issue_directory(issue_identifier), file_name)
  end

  defp find_session(session_id) do
    manifest_glob = Path.join([root(), @issues_dir, "*", @manifest_filename])

    manifest_glob
    |> Path.wildcard()
    |> Enum.reduce_while({:error, :session_not_found}, fn path, _acc ->
      case load_manifest(path, %{}, issue_identifier_from_manifest_path(path)) do
        {:ok, manifest} ->
          reduce_manifest_session(manifest, session_id)

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp load_manifest(path, issue, issue_identifier) do
    if File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, manifest} <- Jason.decode(content) do
        {:ok, normalize_manifest(manifest, issue_identifier)}
      else
        {:error, reason} -> {:error, {:manifest_read_failed, path, reason}}
      end
    else
      {:ok,
       %{
         "issue_id" => issue_id(issue),
         "issue_identifier" => issue_identifier,
         "sessions" => []
       }}
    end
  end

  defp normalize_manifest(%{"issue_identifier" => issue_identifier, "sessions" => sessions} = manifest, _default_issue_identifier)
       when is_binary(issue_identifier) and is_list(sessions) do
    manifest
  end

  defp normalize_manifest(%{"sessions" => sessions} = manifest, default_issue_identifier) when is_list(sessions) do
    Map.put(manifest, "issue_identifier", default_issue_identifier)
  end

  defp normalize_manifest(_manifest, default_issue_identifier) do
    %{"issue_id" => @default_issue_id, "issue_identifier" => default_issue_identifier, "sessions" => []}
  end

  defp find_or_initialize_session(sessions, session_id, message, workspace_context, timestamp) do
    case Enum.find_index(sessions, &(&1["session_id"] == session_id)) do
      nil ->
        started_at = iso8601(timestamp)

        session =
          %{
            "session_id" => session_id,
            "thread_id" => context_value(message, workspace_context, :thread_id),
            "turn_id" => context_value(message, workspace_context, :turn_id),
            "status" => status_for_event(message[:event]),
            "started_at" => started_at,
            "ended_at" => terminal_timestamp(message[:event], started_at),
            "event_count" => 0,
            "turn_count" => 1,
            "worker_host" => context_value(message, workspace_context, :worker_host),
            "workspace_path" => context_value(message, workspace_context, :workspace_path),
            "file_name" => safe_path_component(session_id) <> ".ndjson",
            "last_event" => nil,
            "last_method" => nil,
            "last_summary" => nil,
            "last_event_at" => nil
          }

        {session, nil}

      index ->
        {Enum.at(sessions, index), index}
    end
  end

  defp build_envelope(issue_id, issue_identifier, session_id, message, workspace_context, timestamp, session_summary) do
    sequence = (session_summary["event_count"] || 0) + 1
    payload = normalized_event_payload(message)

    %{
      "sequence" => sequence,
      "ts" => iso8601(timestamp),
      "issue_id" => issue_id,
      "issue_identifier" => issue_identifier,
      "session_id" => session_id,
      "thread_id" => context_value(message, workspace_context, :thread_id),
      "turn_id" => context_value(message, workspace_context, :turn_id),
      "worker_host" => context_value(message, workspace_context, :worker_host),
      "workspace_path" => context_value(message, workspace_context, :workspace_path),
      "event" => Atom.to_string(message[:event]),
      "method" => message_method(message),
      "summary" => StatusDashboard.humanize_codex_message(message),
      "data" => payload
    }
  end

  defp update_session_summary(session_summary, envelope) do
    Map.merge(session_summary, %{
      "thread_id" => envelope["thread_id"] || session_summary["thread_id"],
      "turn_id" => envelope["turn_id"] || session_summary["turn_id"],
      "status" => status_for_envelope_event(envelope["event"], session_summary["status"]),
      "event_count" => envelope["sequence"],
      "worker_host" => envelope["worker_host"] || session_summary["worker_host"],
      "workspace_path" => envelope["workspace_path"] || session_summary["workspace_path"],
      "ended_at" => terminal_timestamp(envelope["event"], envelope["ts"], session_summary["ended_at"]),
      "last_event" => envelope["event"],
      "last_method" => envelope["method"],
      "last_summary" => envelope["summary"],
      "last_event_at" => envelope["ts"]
    })
  end

  defp put_session_summary(manifest, nil, session_summary) do
    Map.update!(manifest, "sessions", fn sessions -> [session_summary | sessions] end)
  end

  defp put_session_summary(manifest, index, session_summary) when is_integer(index) do
    Map.update!(manifest, "sessions", &List.replace_at(&1, index, session_summary))
  end

  defp append_ndjson_line(path, envelope) do
    line = Jason.encode!(envelope) <> "\n"
    File.write(path, line, [:append])
  end

  defp write_json_atomic(path, data) do
    tmp_path = path <> ".tmp-#{System.unique_integer([:positive])}"
    encoded = Jason.encode!(data)

    with :ok <- File.write(tmp_path, encoded),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, {:manifest_write_failed, path, reason}}
    end
  end

  defp collect_recent_events(issue_identifier, sessions, event_limit) do
    Enum.reduce_while(sessions, [], fn session, acc ->
      collect_recent_session_events(issue_identifier, session, event_limit, acc)
    end)
  end

  defp collect_recent_session_events(_issue_identifier, _session, event_limit, acc)
       when length(acc) >= event_limit do
    {:halt, acc}
  end

  defp collect_recent_session_events(issue_identifier, session, event_limit, acc) do
    remaining = event_limit - length(acc)

    case read_session_file_events(issue_identifier, session) do
      {:ok, session_events} ->
        tail_events =
          session_events
          |> Enum.sort_by(&event_sequence/1, :desc)
          |> Enum.take(remaining)

        {:cont, acc ++ tail_events}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp finalize_recent_events({:error, reason}, _event_limit), do: {:error, reason}

  defp finalize_recent_events(collected, event_limit) do
    collected =
      collected
      |> Enum.sort_by(&sort_key_for_event/1, {:desc, DateTime})
      |> Enum.take(event_limit)

    {:ok, collected}
  end

  defp read_session_file_events(issue_identifier, session) do
    session_path = session_path(issue_identifier, session)

    case File.exists?(session_path) do
      true -> read_session_events_from_file(session_path)
      false -> {:error, {:session_file_missing, session_path}}
    end
  end

  defp read_session_events_from_file(session_path) do
    session_path
    |> File.stream!([], :line)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      decode_session_event_line(line, session_path, acc)
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_session_event_line(line, session_path, acc) do
    case Jason.decode(line) do
      {:ok, event} ->
        {:cont, {:ok, [event | acc]}}

      {:error, reason} ->
        {:halt, {:error, {:invalid_transcript_event, session_path, reason}}}
    end
  end

  defp reduce_manifest_session(manifest, session_id) do
    case Enum.find(manifest["sessions"], &(&1["session_id"] == session_id)) do
      nil ->
        {:cont, {:error, :session_not_found}}

      session ->
        {:halt, {:ok, %{issue_identifier: manifest["issue_identifier"], session: session}}}
    end
  end

  defp normalize_limit(limit) when is_integer(limit), do: min(max(limit, 1), @max_page_limit)
  defp normalize_limit(_limit), do: @default_page_limit

  defp normalize_order(order) when order in [:asc, :desc], do: order
  defp normalize_order("asc"), do: :asc
  defp normalize_order("desc"), do: :desc
  defp normalize_order(_order), do: :desc

  defp normalize_cursor(nil), do: nil
  defp normalize_cursor(cursor) when is_integer(cursor) and cursor > 0, do: cursor

  defp normalize_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp normalize_cursor(_cursor), do: nil

  defp order_events(events, :asc), do: Enum.sort_by(events, &event_sequence/1, :asc)
  defp order_events(events, :desc), do: Enum.sort_by(events, &event_sequence/1, :desc)

  defp apply_cursor(events, nil, _order), do: events
  defp apply_cursor(events, cursor, :asc), do: Enum.reject(events, &(event_sequence(&1) <= cursor))
  defp apply_cursor(events, cursor, :desc), do: Enum.reject(events, &(event_sequence(&1) >= cursor))

  defp next_cursor([], _has_more?), do: nil
  defp next_cursor(_events, false), do: nil

  defp next_cursor(events, true) do
    events
    |> List.last()
    |> event_sequence()
  end

  defp event_sequence(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  defp event_sequence(_event), do: 0

  defp sort_key_for_session(session) do
    date_time_or_min(session["started_at"]) || date_time_or_min(session["last_event_at"])
  end

  defp sort_key_for_event(event) do
    date_time_or_min(event["ts"])
  end

  defp date_time_or_min(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> ~U[0000-01-01 00:00:00Z]
    end
  end

  defp date_time_or_min(_value), do: ~U[0000-01-01 00:00:00Z]

  defp issue_id(%Issue{id: issue_id}) when is_binary(issue_id), do: issue_id
  defp issue_id(%{id: issue_id}) when is_binary(issue_id), do: issue_id
  defp issue_id(_issue), do: @default_issue_id

  defp issue_identifier(%Issue{identifier: issue_identifier}) when is_binary(issue_identifier), do: issue_identifier
  defp issue_identifier(%{identifier: issue_identifier}) when is_binary(issue_identifier), do: issue_identifier
  defp issue_identifier(_issue), do: @default_issue_identifier

  defp event_timestamp(%{timestamp: %DateTime{} = timestamp}), do: timestamp

  defp event_timestamp(%{timestamp: %NaiveDateTime{} = timestamp}) do
    DateTime.from_naive!(timestamp, "Etc/UTC")
  end

  defp event_timestamp(%{timestamp: timestamp}) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed_timestamp, _offset} ->
        parsed_timestamp

      _ ->
        case NaiveDateTime.from_iso8601(timestamp) do
          {:ok, parsed_naive_timestamp} -> DateTime.from_naive!(parsed_naive_timestamp, "Etc/UTC")
          _ -> DateTime.utc_now()
        end
    end
  end

  defp event_timestamp(_message), do: DateTime.utc_now()

  defp session_id_for(message, workspace_context, timestamp) do
    context_value(message, workspace_context, :session_id) ||
      "startup-failed-#{timestamp |> DateTime.to_unix(:microsecond) |> Integer.to_string()}"
  end

  defp session_file_name(%{"file_name" => file_name}) when is_binary(file_name), do: file_name
  defp session_file_name(_session_summary), do: "session.ndjson"

  defp context_value(message, workspace_context, key) do
    Map.get(message, key) || Map.get(workspace_context, key)
  end

  defp status_for_event(:turn_completed), do: "completed"
  defp status_for_event(:turn_failed), do: "failed"
  defp status_for_event(:turn_cancelled), do: "cancelled"
  defp status_for_event(:turn_ended_with_error), do: "error"
  defp status_for_event(:startup_failed), do: "startup_failed"
  defp status_for_event(_event), do: "running"

  defp status_for_envelope_event("turn_completed", _current_status), do: "completed"
  defp status_for_envelope_event("turn_failed", _current_status), do: "failed"
  defp status_for_envelope_event("turn_cancelled", _current_status), do: "cancelled"
  defp status_for_envelope_event("turn_ended_with_error", _current_status), do: "error"
  defp status_for_envelope_event("startup_failed", _current_status), do: "startup_failed"
  defp status_for_envelope_event(_event, current_status), do: current_status || "running"

  defp terminal_timestamp(:turn_completed, timestamp), do: iso8601(timestamp)
  defp terminal_timestamp(:turn_failed, timestamp), do: iso8601(timestamp)
  defp terminal_timestamp(:turn_cancelled, timestamp), do: iso8601(timestamp)
  defp terminal_timestamp(:turn_ended_with_error, timestamp), do: iso8601(timestamp)
  defp terminal_timestamp(:startup_failed, timestamp), do: iso8601(timestamp)
  defp terminal_timestamp(_event, _timestamp), do: nil

  defp terminal_timestamp("turn_completed", timestamp, _existing), do: timestamp
  defp terminal_timestamp("turn_failed", timestamp, _existing), do: timestamp
  defp terminal_timestamp("turn_cancelled", timestamp, _existing), do: timestamp
  defp terminal_timestamp("turn_ended_with_error", timestamp, _existing), do: timestamp
  defp terminal_timestamp("startup_failed", timestamp, _existing), do: timestamp
  defp terminal_timestamp(_event, _timestamp, existing), do: existing

  defp message_method(%{payload: %{"method" => method}}) when is_binary(method), do: method
  defp message_method(%{payload: %{method: method}}) when is_binary(method), do: method
  defp message_method(_message), do: nil

  defp normalized_event_payload(message) do
    message
    |> Enum.into(%{}, fn {key, value} ->
      {to_string(key), json_safe(value)}
    end)
  end

  defp json_safe(%DateTime{} = datetime), do: iso8601(datetime)
  defp json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, nested_value} ->
      {to_string(key), json_safe(nested_value)}
    end)
  end

  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)
  defp json_safe(value), do: inspect(value)

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp iso8601(%NaiveDateTime{} = naive_datetime) do
    naive_datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> iso8601()
  end

  defp iso8601(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, parsed_datetime, _offset} ->
        iso8601(parsed_datetime)

      _ ->
        case NaiveDateTime.from_iso8601(datetime) do
          {:ok, parsed_naive_datetime} -> iso8601(parsed_naive_datetime)
          _ -> datetime
        end
    end
  end

  defp issue_identifier_from_manifest_path(path) do
    path
    |> Path.dirname()
    |> Path.basename()
  end

  defp safe_path_component(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    |> case do
      "" -> "unknown"
      sanitized -> sanitized
    end
  end
end
