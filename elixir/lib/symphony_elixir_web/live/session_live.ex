defmodule SymphonyElixirWeb.SessionLive do
  @moduledoc """
  Human-readable transcript inspector for a single Codex session.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{ObservabilityPubSub, Presenter}

  @default_limit 100
  @default_order "asc"
  @default_view "condensed"
  @streaming_summary_prefixes [
    "agent message streaming",
    "agent message content streaming",
    "reasoning streaming",
    "reasoning content streaming",
    "reasoning text streaming",
    "reasoning summary streaming",
    "plan streaming",
    "command output streaming",
    "file change output streaming"
  ]

  @stream_kind_matchers [
    {"assistant", "agentmessage", "agent message"},
    {"reasoning", "reasoning", "reasoning"},
    {"plan", "plan", "plan streaming"},
    {"command", "commandexecution", "command output"},
    {"file", "filechange", "file change output"}
  ]

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
          view_mode: normalize_view_mode(query["view"]),
          page: %{cursor: nil, next_cursor: nil, has_more: false},
          query: query
        }

      {:ok, payload} ->
        view_mode = normalize_view_mode(query["view"])
        raw_events = payload.events
        condensed_events = condense_events(raw_events)
        display_events = if(view_mode == "raw", do: raw_events, else: condensed_events)
        raw_event_count = length(payload.events)
        displayed_event_count = length(display_events)

        %{
          error: nil,
          session: payload.session,
          issue_identifier: payload.issue_identifier,
          events: display_events,
          raw_event_count: raw_event_count,
          displayed_event_count: displayed_event_count,
          condensed_event_count: max(raw_event_count - displayed_event_count, 0),
          view_mode: view_mode,
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
          view_mode: normalize_view_mode(query["view"]),
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
      "view" => Map.get(params, "view", @default_view)
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

  defp streaming_event?(event) do
    method = event_method(event) |> String.downcase()
    summary = event_summary(event) |> String.downcase()

    String.contains?(method, "delta") or starts_with_any?(summary, @streaming_summary_prefixes)
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

    Enum.find_value(@stream_kind_matchers, "stream", fn {kind, method_fragment, summary_prefix} ->
      if String.contains?(method, method_fragment) or String.starts_with?(summary, summary_prefix), do: kind
    end)
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

  defp starts_with_any?(value, prefixes) when is_binary(value) and is_list(prefixes) do
    Enum.any?(prefixes, &String.starts_with?(value, &1))
  end

  defp starts_with_any?(_value, _prefixes), do: false

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
