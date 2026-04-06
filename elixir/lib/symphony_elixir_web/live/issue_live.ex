defmodule SymphonyElixirWeb.IssueLive do
  @moduledoc """
  Live transcript inspector for a single Symphony issue.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @default_limit 50
  @default_order "desc"

  @impl true
  def mount(%{"issue_identifier" => issue_identifier}, _session, socket) do
    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
    end

    {:ok,
     socket
     |> assign(:issue_identifier, issue_identifier)
     |> assign(:payload, load_payload(issue_identifier, %{}))
     |> assign(:current_params, %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    issue_identifier = Map.get(params, "issue_identifier", socket.assigns.issue_identifier)

    {:noreply,
     socket
     |> assign(:issue_identifier, issue_identifier)
     |> assign(:current_params, Map.drop(params, ["issue_identifier"]))
     |> assign(:payload, load_payload(issue_identifier, params))}
  end

  @impl true
  def handle_event("select_session", %{"session_id" => session_id}, socket) do
    params =
      socket.assigns.current_params
      |> Map.drop(["cursor"])
      |> Map.put("session_id", session_id)

    {:noreply, push_patch(socket, to: issue_path(socket.assigns.issue_identifier, params))}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload, load_payload(socket.assigns.issue_identifier, socket.assigns.current_params))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <%= if @payload.error do %>
        <section class="error-card">
          <h2 class="error-title">Transcript unavailable</h2>
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
                Transcript
              </p>
              <h1 class="hero-title"><%= @payload.header.issue_identifier %></h1>
              <p class="hero-copy">
                Transcript history, per-session events, and raw Codex payloads for this issue.
              </p>
            </div>

            <div class="status-stack">
              <span class={state_badge_class(@payload.header.status)}>
                <%= @payload.header.status %>
              </span>
            </div>
          </div>
        </header>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Issue ID</p>
            <p class="metric-value mono"><%= @payload.header.issue_id || "n/a" %></p>
            <p class="metric-detail">Current issue identifier in the active runtime or transcript manifest.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Sessions</p>
            <p class="metric-value numeric"><%= length(@payload.transcript.sessions) %></p>
            <p class="metric-detail">Persisted Codex turns retained for this issue.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Selected session</p>
            <p class="metric-value mono"><%= @payload.selected_session && @payload.selected_session["session_id"] || "n/a" %></p>
            <p class="metric-detail">
              <%= @payload.selected_session && @payload.selected_session["status"] || "No session selected" %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Transcript API</p>
            <p class="metric-value"><%= if @payload.transcript.enabled, do: "Enabled", else: "Disabled" %></p>
            <p class="metric-detail">Issue transcript JSON and NDJSON downloads stay outside issue workspaces.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Links</h2>
              <p class="section-copy">Quick access to the transcript APIs for this issue and the selected session.</p>
            </div>
          </div>

          <div class="issue-links issue-links-actions">
            <a class="issue-link" href={@payload.transcript.transcript_url}>Issue transcript JSON</a>
            <a :if={@payload.summary} class="issue-link" href={"/api/v1/#{@payload.header.issue_identifier}"}>Issue summary JSON</a>
            <a :if={@payload.selected_session} class="issue-link" href={@payload.selected_session["url"]}>Session JSON</a>
            <a :if={@payload.selected_session} class="issue-link" href={@payload.selected_session["ndjson_url"]}>Session NDJSON</a>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Recent issue events</h2>
              <p class="section-copy">Latest transcript summaries across sessions for this issue.</p>
            </div>
          </div>

          <%= if @payload.transcript.recent_events == [] do %>
            <p class="empty-state">No transcript events have been captured yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>At</th>
                    <th>Event</th>
                    <th>Method</th>
                    <th>Summary</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={event <- @payload.transcript.recent_events}>
                    <td class="mono"><%= event[:at] || "n/a" %></td>
                    <td><%= event[:event] || "n/a" %></td>
                    <td class="mono"><%= event[:method] || "n/a" %></td>
                    <td><%= event[:message] || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Session transcript</h2>
              <p class="section-copy">Select a session to inspect event order, payloads, and download links.</p>
            </div>
          </div>

          <%= if @payload.transcript.sessions == [] do %>
            <p class="empty-state">No sessions recorded for this issue.</p>
          <% else %>
            <form id="session-selector-form" phx-change="select_session" class="session-controls">
              <label class="eyebrow" for="session_id">Session</label>
              <select id="session_id" name="session_id" class="select-input">
                <option :for={session <- @payload.transcript.sessions} value={session["session_id"]} selected={session["session_id"] == @payload.selected_session["session_id"]}>
                  <%= session["label"] %> · <%= session["status"] %> · <%= session["event_count"] %> events
                </option>
              </select>
            </form>

            <div class="issue-links issue-links-actions">
              <.link :if={@payload.page.cursor} patch={issue_path(@payload.header.issue_identifier, Map.drop(@payload.query, ["cursor"]))} class="issue-link">
                Latest events
              </.link>
              <.link :if={@payload.page.next_cursor} patch={issue_path(@payload.header.issue_identifier, Map.put(@payload.query, "cursor", to_string(@payload.page.next_cursor)))} class="issue-link">
                Older events
              </.link>
            </div>

            <div class="table-wrap">
              <table class="data-table data-table-running transcript-table">
                <colgroup>
                  <col style="width: 5rem;" />
                  <col style="width: 12rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 16rem;" />
                  <col />
                </colgroup>
                <thead>
                  <tr>
                    <th>Seq</th>
                    <th>Timestamp</th>
                    <th>Event</th>
                    <th>Method</th>
                    <th>Summary / details</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={event <- @payload.events}>
                    <td class="mono numeric"><%= event["sequence"] %></td>
                    <td class="mono"><%= event["ts"] %></td>
                    <td><%= event["event"] %></td>
                    <td class="mono"><%= event["method"] || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span><%= event["summary"] || "n/a" %></span>
                        <details class="event-details">
                          <summary>Raw payload</summary>
                          <pre class="code-panel"><%= inspect(event["data"], pretty: true, limit: :infinity) %></pre>
                        </details>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload(issue_identifier, params) do
    case Presenter.transcript_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, transcript} ->
        summary =
          case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
            {:ok, payload} -> payload
            _ -> nil
          end

        query = normalize_query(params)
        sessions = transcript.sessions
        selected_session = select_session(sessions, query["session_id"])
        session_data = load_session_data(selected_session, query)

        %{
          error: nil,
          header: %{
            issue_identifier: issue_identifier,
            issue_id: transcript.issue_id || (summary && summary.issue_id),
            status: transcript.status
          },
          summary: summary,
          transcript: transcript,
          selected_session: session_data.session,
          events: session_data.events,
          page: session_data.page,
          query: query
        }

      {:error, :issue_not_found} ->
        %{
          error: %{code: "issue_not_found", message: "Issue not found"},
          header: %{issue_identifier: issue_identifier, issue_id: nil, status: "unknown"},
          summary: nil,
          transcript: %{enabled: false, transcript_url: "/api/v1/#{issue_identifier}/transcript", recent_events: [], sessions: []},
          selected_session: nil,
          events: [],
          page: %{cursor: nil, next_cursor: nil, has_more: false},
          query: normalize_query(params)
        }
    end
  end

  defp load_session_data(nil, query) do
    %{
      session: nil,
      events: [],
      page: %{
        limit: parse_limit(query["limit"]),
        order: query["order"],
        cursor: parse_cursor(query["cursor"]),
        next_cursor: nil,
        has_more: false
      }
    }
  end

  defp load_session_data(session, query) do
    opts =
      [
        limit: parse_limit(query["limit"]),
        order: parse_order(query["order"])
      ]
      |> maybe_put_cursor(parse_cursor(query["cursor"]))

    case Presenter.session_payload(session["session_id"], opts) do
      {:ok, payload} ->
        payload

      {:error, :session_not_found} ->
        %{
          session: nil,
          events: [],
          page: %{
            limit: parse_limit(query["limit"]),
            order: query["order"],
            cursor: nil,
            next_cursor: nil,
            has_more: false
          }
        }
    end
  end

  defp select_session([], _requested_session_id), do: nil

  defp select_session(sessions, requested_session_id) when is_binary(requested_session_id) do
    Enum.find(sessions, &(&1["session_id"] == requested_session_id)) || List.first(sessions)
  end

  defp select_session(sessions, _requested_session_id), do: List.first(sessions)

  defp normalize_query(params) do
    %{
      "session_id" => Map.get(params, "session_id"),
      "cursor" => Map.get(params, "cursor"),
      "limit" => Map.get(params, "limit", Integer.to_string(@default_limit)),
      "order" => Map.get(params, "order", @default_order)
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

  defp parse_order("asc"), do: :asc
  defp parse_order(_order), do: :desc

  defp maybe_put_cursor(opts, nil), do: opts
  defp maybe_put_cursor(opts, cursor), do: Keyword.put(opts, :cursor, cursor)

  defp issue_path(issue_identifier, params) do
    query =
      params
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.into(%{})
      |> URI.encode_query()

    if query == "" do
      "/issues/#{issue_identifier}"
    else
      "/issues/#{issue_identifier}?#{query}"
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
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
