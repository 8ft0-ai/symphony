defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.TranscriptStore
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec transcript(Conn.t(), map()) :: Conn.t()
  def transcript(conn, %{"issue_identifier" => issue_identifier} = params) do
    with {:ok, query_opts} <- parse_issue_transcript_query_params(params),
         {:ok, payload} <-
           Presenter.transcript_payload(
             issue_identifier,
             orchestrator(),
             snapshot_timeout_ms(),
             query_opts
           ) do
      json(conn, payload)
    else
      {:error, {:invalid_query_param, param}} ->
        error_response(conn, 400, "invalid_query_param", "Invalid #{param} query parameter")

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec session_route(Conn.t(), map()) :: Conn.t()
  def session_route(conn, %{"session_path" => session_path} = params) when is_list(session_path) do
    joined_path = Enum.join(session_path, "/")

    cond do
      joined_path == "" ->
        not_found(conn, params)

      String.ends_with?(joined_path, ".ndjson") ->
        session_ndjson(conn, Map.put(params, "session_id", String.trim_trailing(joined_path, ".ndjson")))

      length(session_path) == 1 ->
        session(conn, Map.put(params, "session_id", joined_path))

      true ->
        not_found(conn, params)
    end
  end

  @spec session(Conn.t(), map()) :: Conn.t()
  def session(conn, %{"session_id" => session_id} = params) do
    with {:ok, query_opts} <- parse_transcript_query_params(params),
         {:ok, payload} <- Presenter.session_payload(session_id, query_opts) do
      json(conn, payload)
    else
      {:error, {:invalid_query_param, param}} ->
        error_response(conn, 400, "invalid_query_param", "Invalid #{param} query parameter")

      {:error, :session_not_found} ->
        error_response(conn, 404, "session_not_found", "Session not found")
    end
  end

  @spec session_ndjson(Conn.t(), map()) :: Conn.t()
  def session_ndjson(conn, %{"session_id" => session_id}) do
    if TranscriptStore.transcripts_enabled?() == false do
      conn
      |> put_resp_header("content-type", "application/x-ndjson")
      |> put_resp_header("x-symphony-transcripts-enabled", "false")
      |> send_resp(200, "")
    else
      stream_session_ndjson(conn, session_id)
    end
  end

  defp stream_session_ndjson(conn, session_id) do
    case TranscriptStore.issue_session_lookup(session_id) do
      {:ok, %{issue_identifier: issue_identifier, session: session}} ->
        conn
        |> put_resp_header("content-type", "application/x-ndjson")
        |> Conn.send_file(200, TranscriptStore.session_path(issue_identifier, session))

      {:error, :session_not_found} ->
        error_response(conn, 404, "session_not_found", "Session not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp parse_transcript_query_params(params) do
    with {:ok, limit} <- parse_positive_integer_param(params["limit"], :limit),
         {:ok, cursor} <- parse_positive_integer_param(params["cursor"], :cursor),
         {:ok, order} <- parse_order_param(params["order"]) do
      {:ok, Enum.reject([limit && {:limit, limit}, cursor && {:cursor, cursor}, order && {:order, order}], &is_nil/1)}
    end
  end

  defp parse_issue_transcript_query_params(params) do
    with {:ok, session_limit} <-
           parse_positive_integer_param(params["session_limit"], :session_limit),
         {:ok, session_cursor} <- parse_non_negative_integer_param(params["session_cursor"], :session_cursor) do
      {:ok,
       Enum.reject(
         [
           session_limit && {:session_limit, session_limit},
           !is_nil(session_cursor) && {:session_cursor, session_cursor}
         ],
         &(&1 in [nil, false])
       )}
    end
  end

  defp parse_positive_integer_param(nil, _param), do: {:ok, nil}

  defp parse_positive_integer_param(value, param) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, {:invalid_query_param, param}}
    end
  end

  defp parse_positive_integer_param(value, _param) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_positive_integer_param(_value, param), do: {:error, {:invalid_query_param, param}}

  defp parse_non_negative_integer_param(nil, _param), do: {:ok, nil}

  defp parse_non_negative_integer_param(value, param) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> {:error, {:invalid_query_param, param}}
    end
  end

  defp parse_non_negative_integer_param(value, _param) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp parse_non_negative_integer_param(_value, param), do: {:error, {:invalid_query_param, param}}

  defp parse_order_param(nil), do: {:ok, nil}
  defp parse_order_param("asc"), do: {:ok, :asc}
  defp parse_order_param("desc"), do: {:ok, :desc}
  defp parse_order_param(:asc), do: {:ok, :asc}
  defp parse_order_param(:desc), do: {:ok, :desc}
  defp parse_order_param(_value), do: {:error, {:invalid_query_param, :order}}
end
