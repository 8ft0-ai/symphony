defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.RunDisposition
  alias SymphonyElixir.TextSanitizer

  @linear_graphql_tool "linear_graphql"
  @report_run_outcome_tool "report_run_outcome"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @report_run_outcome_description """
  Report a structured Symphony run outcome for the current unattended turn. Use this when the run is intentionally blocked and should not be retried automatically.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @report_run_outcome_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["status", "summary"],
    "properties" => %{
      "status" => %{
        "type" => "string",
        "enum" => ["completed", "blocked"],
        "description" => "Structured run outcome status to record with Symphony."
      },
      "summary" => %{
        "type" => "string",
        "description" => "Short human-readable summary of the outcome."
      },
      "reason_code" => %{
        "type" => "string",
        "description" => "Required when status=blocked. Use a stable snake_case blocker code."
      },
      "retryable" => %{
        "type" => "boolean",
        "description" => "Blocked outcomes must set retryable=false when provided."
      },
      "clearance_hint" => %{
        "type" => ["string", "null"],
        "description" => "Short explanation of what must change before Symphony should retry."
      },
      "details" => %{
        "type" => ["object", "null"],
        "description" => "Optional machine-readable context for observability.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @report_run_outcome_tool ->
        execute_report_run_outcome(arguments, opts)

      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @report_run_outcome_tool,
        "description" => @report_run_outcome_description,
        "inputSchema" => @report_run_outcome_input_schema
      },
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_report_run_outcome(arguments, opts) do
    reporter = Keyword.get(opts, :reporter, fn _disposition -> :ok end)

    case RunDisposition.normalize_report_arguments(arguments) do
      {:ok, disposition} ->
        :ok = reporter.(disposition)

        success_response(%{
          "recorded" => %{
            "status" => Atom.to_string(disposition.status),
            "reasonCode" => disposition.reason_code,
            "summary" => disposition.summary,
            "retryable" => disposition.retryable,
            "clearanceHint" => disposition.clearance_hint,
            "details" => disposition.details
          }
        })

      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case query |> String.trim() |> TextSanitizer.sanitize_user_visible_text() do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, TextSanitizer.sanitize_graphql_value(variables)}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp success_response(payload) do
    dynamic_tool_response(true, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_report_arguments) do
    %{
      "error" => %{
        "message" => "`report_run_outcome` expects an object with only `status`, `summary`, `reason_code`, `retryable`, `clearance_hint`, and `details`."
      }
    }
  end

  defp tool_error_payload(:missing_report_status) do
    %{
      "error" => %{
        "message" => "`report_run_outcome` requires a `status` of `completed` or `blocked`."
      }
    }
  end

  defp tool_error_payload(:invalid_report_status) do
    %{
      "error" => %{
        "message" => "`report_run_outcome.status` must be either `completed` or `blocked`."
      }
    }
  end

  defp tool_error_payload(:missing_report_summary) do
    %{
      "error" => %{
        "message" => "`report_run_outcome` requires a non-empty `summary` string."
      }
    }
  end

  defp tool_error_payload(:invalid_report_text) do
    %{
      "error" => %{
        "message" => "`report_run_outcome.summary` and `clearance_hint` must be strings when provided."
      }
    }
  end

  defp tool_error_payload(:missing_report_reason_code) do
    %{
      "error" => %{
        "message" => "`report_run_outcome` requires `reason_code` when `status` is `blocked`."
      }
    }
  end

  defp tool_error_payload(:invalid_report_reason_code) do
    %{
      "error" => %{
        "message" => "`report_run_outcome.reason_code` must be a non-empty snake_case string such as `git_metadata_writes_unavailable`."
      }
    }
  end

  defp tool_error_payload(:invalid_report_retryable) do
    %{
      "error" => %{
        "message" => "`report_run_outcome.retryable` must be boolean when provided, and blocked outcomes must leave it false."
      }
    }
  end

  defp tool_error_payload(:invalid_report_details) do
    %{
      "error" => %{
        "message" => "`report_run_outcome.details` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
