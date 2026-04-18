defmodule SymphonyElixirWeb.SessionLive do
  @moduledoc """
  Human-readable transcript inspector for a single Codex session.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{ObservabilityPubSub, Presenter}

  @default_limit 100
  @default_order "desc"
  @default_view "condensed"
  @default_tab "checkin"
  @collapsible_infra_methods MapSet.new([
                              "mcpServer/startupStatus/updated",
                              "thread/status/changed"
                            ])

  @impl true
  def mount(%{"session_id" => session_id}, _session, socket) do
    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
    end

    {:ok,
     socket
     |> assign(:session_id, session_id)
     |> assign(:current_params, %{})
     |> assign(:payload, load_payload(session_id, %{}))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    session_id = Map.get(params, "session_id", socket.assigns.session_id)

    {:noreply,
     socket
     |> assign(:session_id, session_id)
     |> assign(:current_params, Map.drop(params, ["session_id"]))
     |> assign(:payload, load_payload(session_id, params))}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload, load_payload(socket.assigns.session_id, socket.assigns.current_params))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <%= if @payload.error do %>
        <section class="error-card">
          <h2 class="error-title">Session unavailable</h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <header class="hero-card">
          <div class="hero-grid">
            <div>
              <p class="eyebrow">
                <a href="/">Dashboard</a>
                <span class="muted">/</span>
                <a href={"/issues/#{@payload.issue_identifier}"}><%= @payload.issue_identifier %></a>
                <span class="muted">/</span>
                Session
              </p>
              <h1 class="hero-title"><%= @payload.session["session_id"] %></h1>
              <p class="hero-copy">
                Human-readable event timeline for one running or completed Codex session.
              </p>
            </div>

            <div class="status-stack">
              <span class={state_badge_class(@payload.session["status"])}>
                <%= @payload.session["status"] %>
              </span>
            </div>
          </div>
        </header>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Issue</p>
            <p class="metric-value mono"><%= @payload.issue_identifier || "n/a" %></p>
            <p class="metric-detail">Parent issue for this session transcript.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Events</p>
            <p class="metric-value numeric"><%= @payload.session["event_count"] || length(@payload.events) %></p>
            <p class="metric-detail">Total captured events in this session.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Started</p>
            <p class="metric-value mono"><%= @payload.session["started_at"] || "n/a" %></p>
            <p class="metric-detail">Session start timestamp.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Worker</p>
            <p class="metric-value mono"><%= @payload.session["worker_host"] || "local" %></p>
            <p class="metric-detail">Worker host and workspace context.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Now</h2>
              <p class="section-copy">Current run posture and latest meaningful update for quick operator check-ins.</p>
            </div>
          </div>

          <div class="metric-grid">
            <article class="metric-card">
              <p class="metric-label">Current phase</p>
              <p class="metric-value"><%= @payload.now.phase %></p>
              <p class="metric-detail">Latest inferred execution phase.</p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Updated</p>
              <p class="metric-value mono"><%= @payload.now.updated_ago %></p>
              <p class="metric-detail"><%= @payload.now.last_update_at || "n/a" %></p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Health</p>
              <p class="metric-value"><%= @payload.now.health %></p>
              <p class="metric-detail"><%= @payload.now.health_reason %></p>
            </article>
          </div>

          <div class="timeline-event" style="margin-top: 0.9rem;">
            <div class="timeline-meta">
              <span class="state-badge state-badge-active">latest</span>
              <span class="mono"><%= @payload.now.last_update_method || "n/a" %></span>
            </div>
            <p class="timeline-summary"><%= @payload.now.last_update || "No meaningful updates yet." %></p>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Links</h2>
              <p class="section-copy">API access for machine-level details when needed.</p>
            </div>
          </div>

          <div class="issue-links issue-links-actions">
            <a class="issue-link" href={"/issues/#{@payload.issue_identifier}"}>Issue transcript</a>
            <a class="issue-link" href={@payload.session["url"]}>Session JSON</a>
            <a class="issue-link" href={@payload.session["ndjson_url"]}>Session NDJSON</a>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Session Conversation</h2>
              <p class="section-copy">
                Ordered event timeline with concise summaries. Streaming and repetitive infra updates are condensed.
                Expand an item only when you need the raw payload.
              </p>
            </div>

            <div class="issue-links">
              <.link
                patch={session_path(@payload.session["session_id"], Map.put(@payload.query, "tab", "checkin"))}
                class={if(@payload.tab_mode == "checkin", do: "issue-link active-toggle", else: "issue-link")}
              >
                Check-in
              </.link>
              <.link
                patch={session_path(@payload.session["session_id"], Map.put(@payload.query, "tab", "debug"))}
                class={if(@payload.tab_mode == "debug", do: "issue-link active-toggle", else: "issue-link")}
              >
                Debug
              </.link>
              <%= if @payload.tab_mode == "debug" do %>
                <.link
                  patch={session_path(@payload.session["session_id"], Map.put(@payload.query, "view", "condensed"))}
                  class={if(@payload.view_mode == "condensed", do: "issue-link active-toggle", else: "issue-link")}
                >
                  Condensed
                </.link>
                <.link
                  patch={session_path(@payload.session["session_id"], Map.put(@payload.query, "view", "raw"))}
                  class={if(@payload.view_mode == "raw", do: "issue-link active-toggle", else: "issue-link")}
                >
                  Raw
                </.link>
              <% end %>
            </div>
          </div>

          <%= if @payload.events == [] do %>
            <p class="empty-state">No events available for this session.</p>
          <% else %>
            <p :if={@payload.condensed_event_count > 0} class="empty-state">
              Showing <span class="mono"><%= @payload.displayed_event_count %></span> timeline rows from
              <span class="mono"><%= @payload.raw_event_count %></span> raw events.
            </p>

            <div class="session-timeline">
              <article :for={event <- @payload.events} class="timeline-event">
                <div class="timeline-meta">
                  <span class={timeline_chip_class(event)}><%= timeline_chip_label(event) %></span>
                  <span class="mono">#<%= event["sequence"] %></span>
                  <span class="mono"><%= event["ts"] %></span>
                  <span class="mono"><%= event["method"] || event["event"] %></span>
                </div>
                <p class="timeline-summary"><%= event["summary"] || "n/a" %></p>
                <details class="event-details">
                  <summary>Raw payload</summary>
                  <pre class="code-panel"><%= inspect(event["data"], pretty: true, limit: :infinity) %></pre>
                </details>
              </article>
            </div>

            <div class="issue-links issue-links-actions">
              <.link :if={@payload.page.cursor} patch={session_path(@payload.session["session_id"], Map.drop(@payload.query, ["cursor"]))} class="issue-link">
                Latest events
              </.link>
              <.link :if={@payload.page.next_cursor} patch={session_path(@payload.session["session_id"], Map.put(@payload.query, "cursor", to_string(@payload.page.next_cursor)))} class="issue-link">
                Older events
              </.link>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload(session_id, params) do
    query = normalize_query(params)

    opts =
      [
        limit: parse_limit(query["limit"]),
        order: parse_order(query["order"])
      ]
      |> maybe_put_cursor(parse_cursor(query["cursor"]))

    case Presenter.session_payload(session_id, opts) do
      {:ok, %{session: nil}} ->
        %{
          error: %{code: "session_not_found", message: "Session not found"},
          session: nil,
          issue_identifier: nil,
          events: [],
          raw_event_count: 0,
          displayed_event_count: 0,
          condensed_event_count: 0,
          now: empty_now_snapshot(),
          view_mode: normalize_view_mode(query["view"]),
          tab_mode: normalize_tab_mode(query["tab"]),
          page: %{cursor: nil, next_cursor: nil, has_more: false},
          query: query
        }

      {:ok, payload} ->
        view_mode = normalize_view_mode(query["view"])
        tab_mode = normalize_tab_mode(query["tab"])
        raw_events = payload.events
        condensed_events = condense_events(raw_events)
        display_events = if(view_mode == "raw", do: raw_events, else: condensed_events)
        scoped_events = apply_tab_scope(display_events, tab_mode)
        projected_events = apply_checkin_projection(scoped_events, tab_mode)
        raw_event_count = length(payload.events)
        displayed_event_count = length(projected_events)
        now_snapshot = build_now_snapshot(payload.session, raw_events, condensed_events)

        %{
          error: nil,
          session: payload.session,
          issue_identifier: payload.issue_identifier,
          events: projected_events,
          raw_event_count: raw_event_count,
          displayed_event_count: displayed_event_count,
          condensed_event_count: max(raw_event_count - displayed_event_count, 0),
          now: now_snapshot,
          view_mode: view_mode,
          tab_mode: tab_mode,
          page: payload.page,
          query: query
        }

      {:error, :session_not_found} ->
        %{
          error: %{code: "session_not_found", message: "Session not found"},
          session: nil,
          issue_identifier: nil,
          events: [],
          raw_event_count: 0,
          displayed_event_count: 0,
          condensed_event_count: 0,
          now: empty_now_snapshot(),
          view_mode: normalize_view_mode(query["view"]),
          tab_mode: normalize_tab_mode(query["tab"]),
          page: %{cursor: nil, next_cursor: nil, has_more: false},
          query: query
        }
    end
  end

  defp normalize_query(params) do
    %{
      "cursor" => Map.get(params, "cursor"),
      "limit" => Map.get(params, "limit", Integer.to_string(@default_limit)),
      "order" => Map.get(params, "order", @default_order),
      "view" => Map.get(params, "view", @default_view),
      "tab" => Map.get(params, "tab", @default_tab)
    }
  end

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} when value > 0 -> value
      _ -> @default_limit
    end
  end

  defp parse_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp parse_limit(_limit), do: @default_limit

  defp parse_cursor(nil), do: nil

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp parse_cursor(cursor) when is_integer(cursor) and cursor > 0, do: cursor
  defp parse_cursor(_cursor), do: nil

  defp parse_order("desc"), do: :desc
  defp parse_order(_order), do: :asc

  defp maybe_put_cursor(opts, nil), do: opts
  defp maybe_put_cursor(opts, cursor), do: Keyword.put(opts, :cursor, cursor)

  defp normalize_view_mode("raw"), do: "raw"
  defp normalize_view_mode(_view_mode), do: "condensed"
  defp normalize_tab_mode("debug"), do: "debug"
  defp normalize_tab_mode(_tab), do: "checkin"

  defp apply_tab_scope(events, "debug"), do: events

  defp apply_tab_scope(events, "checkin") when is_list(events) do
    Enum.reject(events, &noise_event?/1)
  end

  defp apply_tab_scope(events, _tab), do: events

  defp session_path(session_id, params) do
    query =
      params
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.into(%{})
      |> URI.encode_query()

    if query == "" do
      "/sessions/#{session_id}"
    else
      "/sessions/#{session_id}?#{query}"
    end
  end

  defp condense_events(events) when is_list(events) do
    events
    |> Enum.reduce(%{rows: [], stream: nil, infra: nil}, fn event, acc ->
      cond do
        streaming_event?(event) ->
          acc
          |> flush_infra()
          |> absorb_stream_event(event)

        collapsible_infra_event?(event) ->
          acc
          |> flush_stream()
          |> absorb_infra_event(event)

        true ->
          acc
          |> flush_stream()
          |> flush_infra()
          |> append_row(event)
      end
    end)
    |> flush_stream()
    |> flush_infra()
    |> Map.fetch!(:rows)
  end

  defp condense_events(_events), do: []

  defp apply_checkin_projection(events, "checkin") when is_list(events) do
    Enum.map(events, &project_checkin_event/1)
  end

  defp apply_checkin_projection(events, _tab), do: events

  defp project_checkin_event(event) do
    case extract_agent_message_text(event) do
      nil ->
        event

      text ->
        Map.put(event, "summary", "assistant update: #{truncate_text(text, 320)}")
    end
  end

  defp build_now_snapshot(session, raw_events, condensed_events) do
    now = DateTime.utc_now()
    latest_meaningful = latest_meaningful_event(condensed_events)
    phase = infer_phase(session, raw_events)
    last_ts = latest_meaningful && latest_meaningful["ts"]
    age_seconds = age_seconds(last_ts, now)

    {health, health_reason} = infer_health(session, age_seconds)

    %{
      phase: phase,
      last_update: latest_meaningful && latest_meaningful["summary"],
      last_update_method: latest_meaningful && latest_meaningful["method"],
      last_update_at: last_ts,
      updated_ago: format_age(age_seconds),
      health: health,
      health_reason: health_reason
    }
  end

  defp empty_now_snapshot do
    %{
      phase: "unknown",
      last_update: nil,
      last_update_method: nil,
      last_update_at: nil,
      updated_ago: "n/a",
      health: "unknown",
      health_reason: "No session data available."
    }
  end

  defp latest_meaningful_event(events) when is_list(events) do
    events
    |> apply_tab_scope("checkin")
    |> apply_checkin_projection("checkin")
    |> Enum.find(fn event -> not blankish?(event["summary"]) end)
  end

  defp latest_meaningful_event(_events), do: nil

  defp infer_phase(session, raw_events) do
    status = to_string(session["status"] || "")

    cond do
      status in ["completed", "failed", "cancelled"] ->
        status

      true ->
        raw_events
        |> Enum.sort_by(&Map.get(&1, "sequence", 0), :desc)
        |> Enum.find_value("running", &phase_for_event/1)
    end
  end

  defp phase_for_event(event) do
    method = to_string(event["method"] || "")

    cond do
      method == "item/started" ->
        case event_item_type(event) do
          "reasoning" -> "thinking"
          "command execution" -> "acting"
          "dynamic tool call" -> "acting"
          "tool call" -> "acting"
          "agent message" -> "communicating"
          _ -> "running"
        end

      method in ["item/tool/requestUserInput", "tool/requestUserInput", "mcpServer/elicitation/request"] ->
        "waiting"

      method == "turn/completed" ->
        "turn complete"

      true ->
        nil
    end
  end

  defp event_item_type(event) do
    summary =
      event["summary"]
      |> to_string()
      |> String.downcase()

    cond do
      String.contains?(summary, "reasoning") -> "reasoning"
      String.contains?(summary, "command execution") -> "command execution"
      String.contains?(summary, "dynamic tool call") -> "dynamic tool call"
      String.contains?(summary, "tool call") -> "tool call"
      String.contains?(summary, "agent message") -> "agent message"
      true -> "item"
    end
  end

  defp infer_health(session, age_seconds) do
    status = to_string(session["status"] || "")

    cond do
      status in ["failed", "cancelled"] ->
        {"warning", "Session is not running."}

      status == "completed" ->
        {"healthy", "Session completed."}

      is_integer(age_seconds) and age_seconds > 600 ->
        {"warning", "No meaningful update for more than 10 minutes."}

      is_integer(age_seconds) and age_seconds > 180 ->
        {"watch", "No meaningful update for more than 3 minutes."}

      true ->
        {"healthy", "Recent meaningful updates are flowing."}
    end
  end

  defp age_seconds(nil, _now), do: nil

  defp age_seconds(ts, now) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, at, _offset} ->
        max(DateTime.diff(now, at, :second), 0)

      _ ->
        nil
    end
  end

  defp age_seconds(_ts, _now), do: nil

  defp format_age(nil), do: "n/a"
  defp format_age(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp format_age(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp format_age(seconds), do: "#{div(seconds, 3600)}h ago"

  defp blankish?(value) when is_binary(value), do: String.trim(value) == ""
  defp blankish?(nil), do: true
  defp blankish?(_value), do: false

  defp extract_agent_message_text(event) do
    with %{} = data <- event["data"],
         %{} = payload <- data["payload"],
         "item/completed" <- payload["method"],
         %{} = params <- payload["params"],
         %{} = item <- params["item"],
         "agentMessage" <- item["type"],
         text when is_binary(text) <- item["text"],
         trimmed <- String.trim(text),
         false <- trimmed == "" do
      trimmed
    else
      _ -> nil
    end
  end

  defp noise_event?(event) do
    method = event_method(event)

    method in [
      "account/rateLimits/updated",
      "thread/tokenUsage/updated",
      "thread/status/changed",
      "mcpServer/startupStatus/updated"
    ]
  end

  defp streaming_event?(event) do
    method = event_method(event) |> String.downcase()
    summary = event_summary(event) |> String.downcase()

    String.contains?(method, "delta") or
      String.starts_with?(summary, "agent message streaming") or
      String.starts_with?(summary, "agent message content streaming") or
      String.starts_with?(summary, "reasoning streaming") or
      String.starts_with?(summary, "reasoning content streaming") or
      String.starts_with?(summary, "reasoning text streaming") or
      String.starts_with?(summary, "reasoning summary streaming") or
      String.starts_with?(summary, "plan streaming") or
      String.starts_with?(summary, "command output streaming") or
      String.starts_with?(summary, "file change output streaming")
  end

  defp collapsible_infra_event?(event) do
    MapSet.member?(@collapsible_infra_methods, event_method(event))
  end

  defp absorb_stream_event(%{stream: nil} = acc, event) do
    kind = stream_kind(event)

    %{acc | stream: %{kind: kind, first: event, last: event, count: 1, previews: stream_previews(event)}}
  end

  defp absorb_stream_event(%{stream: stream} = acc, event) do
    kind = stream_kind(event)

    if stream.kind == kind do
      updated =
        stream
        |> Map.put(:last, event)
        |> Map.update!(:count, &(&1 + 1))
        |> Map.update!(:previews, &(&1 ++ stream_previews(event)))

      %{acc | stream: updated}
    else
      acc
      |> flush_stream()
      |> absorb_stream_event(event)
    end
  end

  defp absorb_infra_event(%{infra: nil} = acc, event) do
    %{acc | infra: %{method: event_method(event), first: event, last: event, count: 1}}
  end

  defp absorb_infra_event(%{infra: infra} = acc, event) do
    method = event_method(event)

    if infra.method == method do
      updated = %{infra | last: event, count: infra.count + 1}
      %{acc | infra: updated}
    else
      acc
      |> flush_infra()
      |> absorb_infra_event(event)
    end
  end

  defp flush_stream(%{stream: nil} = acc), do: acc

  defp flush_stream(%{stream: stream} = acc) do
    label = stream_kind_label(stream.kind)

    preview =
      stream.previews
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate_text(220)

    summary =
      if preview == "" do
        "#{label} (#{stream.count} events)"
      else
        "#{label}: #{preview} (#{stream.count} events)"
      end

    condensed_event =
      build_condensed_event(
        stream.first,
        stream.last,
        "stream/#{stream.kind}",
        summary,
        %{
          "kind" => stream.kind,
          "count" => stream.count,
          "first_data" => stream.first["data"],
          "last_data" => stream.last["data"]
        }
      )

    %{acc | rows: acc.rows ++ [condensed_event], stream: nil}
  end

  defp flush_infra(%{infra: nil} = acc), do: acc

  defp flush_infra(%{infra: %{count: 1, first: first}} = acc) do
    %{acc | rows: acc.rows ++ [first], infra: nil}
  end

  defp flush_infra(%{infra: infra} = acc) do
    summary = "#{infra_method_label(infra.method)} (#{infra.count} updates)"

    condensed_event =
      build_condensed_event(
        infra.first,
        infra.last,
        infra.method,
        summary,
        %{
          "kind" => "infra",
          "count" => infra.count,
          "first_data" => infra.first["data"],
          "last_data" => infra.last["data"]
        }
      )

    %{acc | rows: acc.rows ++ [condensed_event], infra: nil}
  end

  defp append_row(acc, event), do: %{acc | rows: acc.rows ++ [event]}

  defp build_condensed_event(first, last, method, summary, extra_data) do
    %{
      "sequence" => first["sequence"],
      "ts" => first["ts"],
      "event" => first["event"],
      "method" => method,
      "summary" => summary,
      "data" =>
        Map.merge(
          %{
            "condensed" => true,
            "first_sequence" => first["sequence"],
            "last_sequence" => last["sequence"],
            "first_ts" => first["ts"],
            "last_ts" => last["ts"]
          },
          extra_data
        )
    }
  end

  defp stream_kind(event) do
    method = event_method(event) |> String.downcase()
    summary = event_summary(event) |> String.downcase()

    cond do
      String.contains?(method, "agentmessage") or String.starts_with?(summary, "agent message") -> "assistant"
      String.contains?(method, "reasoning") or String.starts_with?(summary, "reasoning") -> "reasoning"
      String.contains?(method, "plan") or String.starts_with?(summary, "plan streaming") -> "plan"
      String.contains?(method, "commandexecution") or String.starts_with?(summary, "command output") -> "command"
      String.contains?(method, "filechange") or String.starts_with?(summary, "file change output") -> "file"
      true -> "stream"
    end
  end

  defp stream_kind_label("assistant"), do: "assistant response"
  defp stream_kind_label("reasoning"), do: "reasoning update"
  defp stream_kind_label("plan"), do: "plan update"
  defp stream_kind_label("command"), do: "command output"
  defp stream_kind_label("file"), do: "file change output"
  defp stream_kind_label(_kind), do: "stream update"

  defp infra_method_label("mcpServer/startupStatus/updated"), do: "mcp startup status updated"
  defp infra_method_label("thread/status/changed"), do: "thread status changed"
  defp infra_method_label(method), do: method

  defp stream_previews(event) do
    case String.split(event_summary(event), ": ", parts: 2) do
      [_label, preview] -> [preview]
      _ -> []
    end
  end

  defp event_method(event), do: to_string(event["method"] || event["event"] || "event")
  defp event_summary(event), do: to_string(event["summary"] || "")

  defp truncate_text(text, max) when is_binary(text) and max > 3 do
    if String.length(text) > max do
      String.slice(text, 0, max - 3) <> "..."
    else
      text
    end
  end

  defp truncate_text(text, _max), do: text

  defp timeline_chip_label(event) do
    method = String.downcase(to_string(event["method"] || ""))
    event_name = String.downcase(to_string(event["event"] || ""))

    cond do
      String.contains?(method, ["agentmessage", "assistant"]) -> "assistant"
      String.contains?(method, ["user", "requestuserinput"]) -> "user"
      String.contains?(method, ["tool", "exec_command"]) -> "tool"
      String.contains?(event_name, ["session", "turn"]) -> "system"
      true -> "event"
    end
  end

  defp timeline_chip_class(event) do
    base = "state-badge"

    case timeline_chip_label(event) do
      "assistant" -> "#{base} state-badge-active"
      "tool" -> "#{base} state-badge-warning"
      "user" -> "#{base} state-badge-warning"
      "system" -> base
      _ -> base
    end
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry", "completed"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end
end
