defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, RunDisposition, Tracker, TranscriptStore, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      {:ok, %RunDisposition{} = disposition} ->
        send_run_disposition(codex_update_recipient, issue, disposition)
        :ok

      {:error, reason} ->
        disposition = RunDisposition.from_app_server_error(reason)
        send_run_disposition(codex_update_recipient, issue, disposition)

        if RunDisposition.blocked?(disposition) do
          Logger.warning(
            "Agent run blocked for #{issue_context(issue)} " <>
              "reason_code=#{disposition.reason_code} summary=#{inspect(disposition.summary)}"
          )

          :ok
        else
          Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
          raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue, workspace_context) do
    context_key = transcript_context_key(issue)
    Process.put(context_key, workspace_context)

    fn message ->
      persist_transcript_event(issue, context_key, workspace_context, message)
      send_codex_update(recipient, issue, message)
    end
  end

  defp persist_transcript_event(issue, context_key, workspace_context, message) do
    transcript_context = next_transcript_context(context_key, workspace_context, message)

    case TranscriptStore.append(issue, transcript_context, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Transcript persistence failed for #{issue_context(issue)} event=#{inspect(message[:event])}: #{inspect(reason)}")

        :ok
    end
  end

  defp next_transcript_context(context_key, workspace_context, message) do
    # Keep a per-handler transcript context in the process dictionary so
    # session/thread/turn identifiers discovered on early events are available
    # to later events in the same turn.
    updated_context =
      Process.get(context_key, workspace_context)
      |> maybe_put_context_value(:session_id, message[:session_id])
      |> maybe_put_context_value(:thread_id, message[:thread_id])
      |> maybe_put_context_value(:turn_id, message[:turn_id])

    Process.put(context_key, updated_context)
    updated_context
  end

  defp maybe_put_context_value(context, _key, value) when value in [nil, ""], do: context
  defp maybe_put_context_value(context, key, value), do: Map.put(context, key, value)

  defp transcript_context_key(%Issue{id: issue_id}) when is_binary(issue_id) do
    {:transcript_context, self(), issue_id}
  end

  defp transcript_context_key(%Issue{identifier: identifier}) when is_binary(identifier) do
    {:transcript_context, self(), identifier}
  end

  defp transcript_context_key(_issue), do: {:transcript_context, self(), make_ref()}

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp send_run_disposition(recipient, %Issue{id: issue_id}, %RunDisposition{} = disposition)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_run_disposition, issue_id, disposition})
    :ok
  end

  defp send_run_disposition(_recipient, _issue, _disposition), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    turn_context = %{
      workspace: workspace,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      worker_host: worker_host,
      max_turns: max_turns
    }

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, issue, turn_context, 1)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, issue, turn_context, turn_number) do
    prompt =
      build_turn_prompt(
        issue,
        turn_context.opts,
        turn_number,
        turn_context.max_turns
      )

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message:
               codex_message_handler(turn_context.codex_update_recipient, issue, %{
                 workspace_path: turn_context.workspace,
                 worker_host: turn_context.worker_host
               })
           ) do
      disposition =
        turn_session[:disposition] ||
          RunDisposition.completed(%{summary: RunDisposition.default_completed_summary()})

      Logger.info(
        "Completed agent run for #{issue_context(issue)} " <>
          "session_id=#{turn_session[:session_id]} " <>
          "workspace=#{turn_context.workspace} " <>
          "turn=#{turn_number}/#{turn_context.max_turns}"
      )

      case disposition.status do
        :blocked ->
          Logger.warning(
            "Agent run reported blocked disposition for #{issue_context(issue)} " <>
              "reason_code=#{disposition.reason_code} summary=#{inspect(disposition.summary)}"
          )

          {:ok, disposition}

        _ ->
          if budget_wait_disposition?(disposition) do
            Logger.info(
              "Codex budget wait detected for #{issue_context(issue)} " <>
                "summary=#{inspect(disposition.summary)}"
            )

            {:ok, disposition}
          else
            continue_after_turn(app_session, issue, disposition, turn_context, turn_number)
          end
      end
    end
  end

  defp continue_after_turn(app_session, issue, disposition, turn_context, turn_number) do
    case continue_with_issue?(issue, turn_context.issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < turn_context.max_turns ->
        Logger.info(
          "Continuing agent run for #{issue_context(refreshed_issue)} " <>
            "after normal turn completion turn=#{turn_number}/#{turn_context.max_turns}"
        )

        do_run_codex_turns(app_session, refreshed_issue, turn_context, turn_number + 1)

      {:continue, refreshed_issue} ->
        Logger.info(
          "Reached agent.max_turns for #{issue_context(refreshed_issue)} " <>
            "with issue still active; returning control to orchestrator"
        )

        {:ok, disposition}

      {:done, _refreshed_issue} ->
        {:ok, disposition}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp budget_wait_disposition?(%RunDisposition{reason_code: "budget_wait"}), do: true
  defp budget_wait_disposition?(_disposition), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
