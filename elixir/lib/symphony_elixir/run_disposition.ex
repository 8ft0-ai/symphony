defmodule SymphonyElixir.RunDisposition do
  @moduledoc """
  Structured run outcomes that survive beyond a single Codex turn.
  """

  alias SymphonyElixir.TextSanitizer

  @enforce_keys [:status, :retryable]
  defstruct [
    :status,
    :reason_code,
    :summary,
    :clearance_hint,
    :reported_at,
    details: %{},
    retryable: true
  ]

  @type status :: :completed | :blocked | :failed

  @type t :: %__MODULE__{
          status: status(),
          reason_code: String.t() | nil,
          summary: String.t() | nil,
          retryable: boolean(),
          clearance_hint: String.t() | nil,
          details: map(),
          reported_at: DateTime.t() | nil
        }

  @status_values ~w[completed blocked failed]
  @known_blocked_reason_codes ~w[
    approval_required
    git_metadata_writes_unavailable
    mcp_elicitation_required
    review_pr_required
    turn_input_required
  ]

  @type report_arguments ::
          %{
            required(:status) => String.t() | atom(),
            optional(:summary) => String.t(),
            optional(:reason_code) => String.t(),
            optional(:retryable) => boolean(),
            optional(:clearance_hint) => String.t() | nil,
            optional(:details) => map() | nil
          }

  @spec status_values() :: [String.t()]
  def status_values, do: @status_values

  @spec known_blocked_reason_codes() :: [String.t()]
  def known_blocked_reason_codes, do: @known_blocked_reason_codes

  @spec completed(map()) :: t()
  def completed(metadata \\ %{}) when is_map(metadata) do
    build(:completed, nil, metadata, true)
  end

  @spec blocked(String.t(), map()) :: t()
  def blocked(reason_code, metadata \\ %{}) when is_binary(reason_code) and is_map(metadata) do
    build(:blocked, normalize_reason_code(reason_code), metadata, false)
  end

  @spec failed(String.t(), map()) :: t()
  def failed(reason_code, metadata \\ %{}) when is_binary(reason_code) and is_map(metadata) do
    retryable = Map.get(metadata, :retryable, Map.get(metadata, "retryable", true))
    build(:failed, normalize_reason_code(reason_code), metadata, retryable != false)
  end

  @spec blocked?(t() | term()) :: boolean()
  def blocked?(%__MODULE__{status: :blocked}), do: true
  def blocked?(_value), do: false

  @spec completed?(t() | term()) :: boolean()
  def completed?(%__MODULE__{status: :completed}), do: true
  def completed?(_value), do: false

  @spec failed?(t() | term()) :: boolean()
  def failed?(%__MODULE__{status: :failed}), do: true
  def failed?(_value), do: false

  @spec normalize_report_arguments(term()) :: {:ok, t()} | {:error, atom()}
  def normalize_report_arguments(arguments) when is_map(arguments) do
    allowed_keys = MapSet.new(~w[status summary reason_code retryable clearance_hint details])

    with :ok <- validate_allowed_keys(arguments, allowed_keys),
         {:ok, status} <- normalize_status(arguments),
         {:ok, summary} <- normalize_required_text(arguments, "summary"),
         {:ok, reason_code} <- normalize_optional_reason_code(arguments),
         {:ok, retryable} <- normalize_retryable(arguments),
         {:ok, clearance_hint} <- normalize_optional_text(arguments, "clearance_hint"),
         {:ok, details} <- normalize_details(arguments),
         :ok <- validate_report_shape(status, reason_code, retryable) do
      disposition =
        case status do
          :completed ->
            completed(%{
              summary: summary,
              details: details,
              reported_at: DateTime.utc_now()
            })

          :blocked ->
            blocked(reason_code, %{
              summary: summary,
              clearance_hint: clearance_hint,
              details: details,
              reported_at: DateTime.utc_now()
            })
        end

      {:ok, disposition}
    end
  end

  def normalize_report_arguments(_arguments), do: {:error, :invalid_report_arguments}

  @spec from_app_server_error(term()) :: t()
  def from_app_server_error({:mcp_elicitation_required, payload}) do
    blocked("mcp_elicitation_required", %{
      summary: summary_from_payload(payload, "MCP elicitation requires operator approval."),
      clearance_hint: "Allow the requested MCP action or rerun in an interactive session.",
      details: %{"payload" => payload}
    })
  end

  def from_app_server_error({:approval_required, payload}) do
    blocked("approval_required", %{
      summary: summary_from_payload(payload, "Command approval is required in unattended mode."),
      clearance_hint: "Grant the required approval or adjust the workflow so the step can run unattended.",
      details: %{"payload" => payload}
    })
  end

  def from_app_server_error({:turn_input_required, payload}) do
    blocked("turn_input_required", %{
      summary: summary_from_payload(payload, "Codex requested input that unattended mode cannot provide."),
      clearance_hint: "Provide the missing context through the issue/workflow, or rerun interactively.",
      details: %{"payload" => payload}
    })
  end

  def from_app_server_error(:turn_timeout) do
    failed("turn_timeout", %{summary: "Codex turn timed out before completion.", retryable: true})
  end

  def from_app_server_error({:port_exit, status}) do
    failed("codex_port_exit", %{
      summary: "Codex app-server exited unexpectedly (status #{status}).",
      retryable: true,
      details: %{"status" => status}
    })
  end

  def from_app_server_error({:turn_failed, payload}) do
    failed("turn_failed", %{
      summary: summary_from_payload(payload, "Codex reported a failed turn."),
      retryable: true,
      details: %{"payload" => payload}
    })
  end

  def from_app_server_error({:turn_cancelled, payload}) do
    failed("turn_cancelled", %{
      summary: summary_from_payload(payload, "Codex cancelled the turn."),
      retryable: true,
      details: %{"payload" => payload}
    })
  end

  def from_app_server_error({:issue_state_refresh_failed, reason}) do
    failed("issue_state_refresh_failed", %{
      summary: "Refreshing the issue state after a turn failed.",
      retryable: true,
      details: %{"reason" => inspect(reason)}
    })
  end

  def from_app_server_error(reason) do
    failed("agent_run_failed", %{
      summary: "Agent run failed unexpectedly.",
      retryable: true,
      details: %{"reason" => inspect(reason)}
    })
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = disposition) do
    %{
      status: disposition.status,
      reason_code: disposition.reason_code,
      summary: disposition.summary,
      retryable: disposition.retryable,
      clearance_hint: disposition.clearance_hint,
      details: disposition.details,
      reported_at: disposition.reported_at
    }
  end

  defp build(status, reason_code, metadata, retryable) do
    %__MODULE__{
      status: status,
      reason_code: reason_code,
      summary: normalize_text(metadata[:summary] || metadata["summary"]),
      retryable: retryable,
      clearance_hint: normalize_optional_text_value(metadata[:clearance_hint] || metadata["clearance_hint"]),
      details: normalize_details_value(metadata[:details] || metadata["details"]),
      reported_at: metadata[:reported_at] || metadata["reported_at"] || DateTime.utc_now()
    }
  end

  defp normalize_status(arguments) do
    case Map.get(arguments, "status") || Map.get(arguments, :status) do
      nil ->
        {:error, :missing_report_status}

      status when is_atom(status) ->
        normalize_status(%{"status" => Atom.to_string(status)})

      status when is_binary(status) ->
        normalized =
          status
          |> String.trim()
          |> String.downcase()

        case normalized do
          "completed" -> {:ok, :completed}
          "blocked" -> {:ok, :blocked}
          _ -> {:error, :invalid_report_status}
        end
    end
  end

  defp validate_allowed_keys(arguments, allowed_keys) do
    invalid_keys =
      arguments
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(allowed_keys, to_string(&1)))

    if invalid_keys == [], do: :ok, else: {:error, :invalid_report_arguments}
  end

  defp normalize_required_text(arguments, key) do
    case normalize_optional_text(arguments, key) do
      {:ok, nil} -> {:error, :missing_report_summary}
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_optional_text(arguments, key) do
    value = Map.get(arguments, key) || Map.get(arguments, String.to_atom(key))

    case value do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case normalize_optional_text_value(value) do
          nil -> {:error, :invalid_report_text}
          text -> {:ok, text}
        end

      _ ->
        {:error, :invalid_report_text}
    end
  end

  defp normalize_optional_reason_code(arguments) do
    case Map.get(arguments, "reason_code") || Map.get(arguments, :reason_code) do
      nil ->
        {:ok, nil}

      reason_code when is_binary(reason_code) ->
        normalized = normalize_reason_code(reason_code)

        if is_binary(normalized) and normalized != "" and String.match?(normalized, ~r/^[a-z0-9_]+$/) do
          {:ok, normalized}
        else
          {:error, :invalid_report_reason_code}
        end

      _ ->
        {:error, :invalid_report_reason_code}
    end
  end

  defp normalize_retryable(arguments) do
    case Map.get(arguments, "retryable") || Map.get(arguments, :retryable) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_report_retryable}
    end
  end

  defp normalize_details(arguments) do
    case Map.get(arguments, "details") || Map.get(arguments, :details) do
      nil -> {:ok, %{}}
      details when is_map(details) -> {:ok, normalize_details_value(details)}
      _ -> {:error, :invalid_report_details}
    end
  end

  defp validate_report_shape(:completed, _reason_code, _retryable), do: :ok

  defp validate_report_shape(:blocked, reason_code, retryable)
       when is_binary(reason_code) and retryable == false,
       do: :ok

  defp validate_report_shape(:blocked, nil, _retryable), do: {:error, :missing_report_reason_code}
  defp validate_report_shape(:blocked, _reason_code, true), do: {:error, :invalid_report_retryable}

  defp normalize_optional_text_value(nil), do: nil

  defp normalize_optional_text_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> TextSanitizer.sanitize_user_visible_text()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(value) when is_binary(value), do: normalize_optional_text_value(value)
  defp normalize_text(_value), do: nil

  defp normalize_reason_code(reason_code) when is_binary(reason_code) do
    reason_code
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
  end

  defp normalize_details_value(details) when is_map(details) do
    details
    |> TextSanitizer.sanitize_graphql_value()
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_details_value(_details), do: %{}

  defp summary_from_payload(payload, fallback) when is_map(payload) do
    [
      ["params", "message"],
      ["params", "reason"],
      ["params", "prompt"],
      ["params", "request", "prompt"],
      ["params", "command"]
    ]
    |> Enum.find_value(fn path -> map_path(payload, path) end)
    |> case do
      value when is_binary(value) ->
        normalize_optional_text_value(value) || fallback

      _ ->
        fallback
    end
  end

  defp summary_from_payload(_payload, fallback), do: fallback

  defp map_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) ->
          {:cont, Map.get(acc, key)}

        is_map(acc) and Map.has_key?(acc, String.to_atom(key)) ->
          {:cont, Map.get(acc, String.to_atom(key))}

        true ->
          {:halt, nil}
      end
    end)
  end
end
