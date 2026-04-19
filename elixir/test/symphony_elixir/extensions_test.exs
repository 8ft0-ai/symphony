defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    contaminated_body = "hello\n<system-reminder>internal only</system-reminder>"

    assert :ok = Adapter.create_comment("issue-1", contaminated_body)
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, refresh, and transcript responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)
    transcripts_root = Path.join(Path.dirname(Workflow.workflow_file_path()), "transcripts")

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      observability_transcripts_root: transcripts_root
    )

    append_test_transcript!(
      %Issue{id: "issue-http", identifier: "MT-HTTP", title: "HTTP transcript", state: "In Progress"},
      "thread-http",
      thread_id: "thread-http",
      turn_id: "turn-1",
      workspace_path: "/tmp/symphony-http"
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload["counts"] == %{"blocked" => 1, "running" => 1, "retrying" => 1}
    assert state_payload["codex_totals"] == %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12, "seconds_running" => 42.5}
    assert state_payload["rate_limits"] == %{"primary" => %{"remaining" => 11}}

    assert [running_entry] = state_payload["running"]
    assert running_entry["issue_id"] == "issue-http"
    assert running_entry["issue_identifier"] == "MT-HTTP"
    assert running_entry["session_id"] == "thread-http"
    assert running_entry["transcript_url"] == "/api/v1/MT-HTTP/transcript"
    assert running_entry["issue_ui_url"] == "/issues/MT-HTTP"
    assert running_entry["last_message"] == "rendered"
    assert running_entry["tokens"] == %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}

    assert [retry_entry] = state_payload["retrying"]
    assert retry_entry["issue_id"] == "issue-retry"
    assert retry_entry["issue_identifier"] == "MT-RETRY"
    assert retry_entry["transcript_url"] == "/api/v1/MT-RETRY/transcript"
    assert retry_entry["issue_ui_url"] == "/issues/MT-RETRY"
    assert retry_entry["attempt"] == 2
    assert retry_entry["error"] == "boom"

    assert [blocked_entry] = state_payload["blocked"]
    assert blocked_entry["issue_id"] == "issue-blocked"
    assert blocked_entry["issue_identifier"] == "MT-BLOCKED"
    assert blocked_entry["reason_code"] == "approval_required"
    assert blocked_entry["summary"] == "Linear requires approval for this mutation."
    assert blocked_entry["clearance_hint"] == "Approve the mutation or adjust the workflow."
    assert blocked_entry["worker_host"] == "worker-b"
    assert blocked_entry["workspace_path"] == "/tmp/symphony-blocked"
    assert blocked_entry["retryable"] == false

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload["issue_identifier"] == "MT-HTTP"
    assert issue_payload["issue_id"] == "issue-http"
    assert issue_payload["status"] == "running"

    assert issue_payload["workspace"] == %{
             "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
             "host" => nil
           }

    assert issue_payload["attempts"] == %{"restart_count" => 0, "current_retry_attempt" => 0}
    assert issue_payload["running"]["session_id"] == "thread-http"
    assert issue_payload["running"]["last_message"] == "rendered"

    assert issue_payload["transcripts"] == %{
             "enabled" => true,
             "transcript_url" => "/api/v1/MT-HTTP/transcript",
             "issue_ui_url" => "/issues/MT-HTTP",
             "recent_events_limit" => 50
           }

    assert [log_entry] = issue_payload["logs"]["codex_session_logs"]
    assert log_entry["label"] == "latest"
    assert log_entry["url"] == "/api/v1/sessions/thread-http.ndjson"
    assert log_entry["path"] == "issues/MT-HTTP/thread-http.ndjson"

    assert Enum.map(issue_payload["recent_events"], & &1["event"]) == [
             "turn_completed",
             "notification",
             "session_started"
           ]

    conn = get(build_conn(), "/api/v1/MT-HTTP/transcript")
    transcript_payload = json_response(conn, 200)

    assert transcript_payload["issue_identifier"] == "MT-HTTP"
    assert transcript_payload["issue_id"] == "issue-http"
    assert transcript_payload["status"] == "running"
    assert transcript_payload["enabled"] == true
    assert transcript_payload["transcript_url"] == "/api/v1/MT-HTTP/transcript"
    assert transcript_payload["issue_ui_url"] == "/issues/MT-HTTP"
    assert transcript_payload["session_count"] == 1

    assert transcript_payload["sessions_page"] == %{
             "limit" => 100,
             "cursor" => nil,
             "next_cursor" => nil,
             "has_more" => false
           }

    assert [session_payload] = transcript_payload["sessions"]
    assert session_payload["session_id"] == "thread-http"
    assert session_payload["url"] == "/api/v1/sessions/thread-http"
    assert session_payload["ndjson_url"] == "/api/v1/sessions/thread-http.ndjson"
    assert session_payload["event_count"] == 3
    assert session_payload["path"] == "issues/MT-HTTP/thread-http.ndjson"

    conn = get(build_conn(), "/api/v1/sessions/thread-http?limit=2&order=asc")
    session_payload = json_response(conn, 200)

    assert session_payload["enabled"] == true
    assert session_payload["issue_identifier"] == "MT-HTTP"
    assert session_payload["session"]["session_id"] == "thread-http"
    assert Enum.map(session_payload["events"], & &1["sequence"]) == [1, 2]

    assert session_payload["page"] == %{
             "limit" => 2,
             "order" => "asc",
             "cursor" => nil,
             "next_cursor" => 2,
             "has_more" => true
           }

    conn = get(build_conn(), "/api/v1/sessions/thread-http.ndjson")
    assert response(conn, 200) =~ "\"session_id\":\"thread-http\""

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix transcript endpoints validate params, preserve route precedence, and return 404s" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityTranscriptValidationOrchestrator)
    transcripts_root = Path.join(Path.dirname(Workflow.workflow_file_path()), "transcripts-validation")

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      observability_transcripts_root: transcripts_root
    )

    append_test_transcript!(
      %Issue{id: "issue-http", identifier: "MT-HTTP", title: "HTTP transcript", state: "In Progress"},
      "thread-http"
    )

    append_test_transcript!(
      %Issue{id: "issue-http", identifier: "MT-HTTP", title: "HTTP transcript", state: "In Progress"},
      "thread-http-older",
      base_time: ~U[2026-04-05 09:00:00Z]
    )

    append_test_transcript!(
      %Issue{id: "issue-http", identifier: "MT-HTTP", title: "HTTP transcript", state: "In Progress"},
      "thread-http-oldest",
      base_time: ~U[2026-04-05 08:00:00Z]
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(get(build_conn(), "/api/v1/sessions/thread-http?limit=bad"), 400) ==
             %{"error" => %{"code" => "invalid_query_param", "message" => "Invalid limit query parameter"}}

    assert json_response(get(build_conn(), "/api/v1/sessions/thread-http?cursor=-1"), 400) ==
             %{"error" => %{"code" => "invalid_query_param", "message" => "Invalid cursor query parameter"}}

    assert json_response(get(build_conn(), "/api/v1/sessions/thread-http?order=sideways"), 400) ==
             %{"error" => %{"code" => "invalid_query_param", "message" => "Invalid order query parameter"}}

    assert json_response(get(build_conn(), "/api/v1/MT-HTTP/transcript?session_limit=bad"), 400) ==
             %{
               "error" => %{
                 "code" => "invalid_query_param",
                 "message" => "Invalid session_limit query parameter"
               }
             }

    assert json_response(get(build_conn(), "/api/v1/MT-HTTP/transcript?session_cursor=-1"), 400) ==
             %{
               "error" => %{
                 "code" => "invalid_query_param",
                 "message" => "Invalid session_cursor query parameter"
               }
             }

    transcript_payload =
      json_response(get(build_conn(), "/api/v1/MT-HTTP/transcript?session_limit=1&session_cursor=1"), 200)

    assert transcript_payload["session_count"] == 3

    assert transcript_payload["sessions_page"] == %{
             "limit" => 1,
             "cursor" => 1,
             "next_cursor" => 2,
             "has_more" => true
           }

    assert Enum.map(transcript_payload["sessions"], & &1["session_id"]) == ["thread-http-older"]

    assert json_response(get(build_conn(), "/api/v1/sessions/missing-session"), 404) ==
             %{"error" => %{"code" => "session_not_found", "message" => "Session not found"}}

    assert json_response(get(build_conn(), "/api/v1/MT-MISSING/transcript"), 404) ==
             %{"error" => %{"code" => "issue_not_found", "message" => "Issue not found"}}

    assert response(get(build_conn(), "/api/v1/sessions/thread-http.ndjson"), 200) =~ "\"sequence\":1"
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "/sessions/thread-http"
    assert html =~ "Codex update"
    assert html =~ "/issues/MT-HTTP"
    assert html =~ "/issues/MT-RETRY"
    assert html =~ ">Transcript<"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "issue transcript liveview renders sessions and switches between them" do
    orchestrator_name = Module.concat(__MODULE__, :IssueTranscriptLiveOrchestrator)
    snapshot = static_snapshot()
    transcripts_root = Path.join(Path.dirname(Workflow.workflow_file_path()), "issue-live-transcripts")

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      observability_transcripts_root: transcripts_root
    )

    append_test_transcript!(
      %Issue{id: "issue-http", identifier: "MT-HTTP", title: "Older transcript", state: "Done"},
      "thread-http-older",
      base_time: ~U[2026-04-05 09:00:00Z],
      delta: "older note",
      turn_id: "turn-older",
      workspace_path: "/tmp/older-session"
    )

    append_test_transcript!(
      %Issue{id: "issue-http", identifier: "MT-HTTP", title: "Latest transcript", state: "In Progress"},
      "thread-http",
      base_time: ~U[2026-04-05 10:00:00Z],
      delta: "newer note",
      turn_id: "turn-latest",
      workspace_path: "/tmp/latest-session"
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/issues/MT-HTTP")
    assert html =~ "Transcript history"
    assert html =~ "Issue transcript JSON"
    assert html =~ "Session NDJSON"
    assert html =~ "thread-http"
    assert html =~ "thread-http-older"
    assert html =~ "newer note"
    refute html =~ "older note"

    view
    |> form("#session-selector-form", %{"session_id" => "thread-http-older"})
    |> render_change()

    assert_patch(view, "/issues/MT-HTTP?session_id=thread-http-older")

    switched_html = render(view)
    assert switched_html =~ "older note"
    assert switched_html =~ "/api/v1/sessions/thread-http-older"
    assert switched_html =~ "/api/v1/sessions/thread-http-older.ndjson"
    assert switched_html =~ "/sessions/thread-http-older"
  end

  test "session liveview renders a readable timeline for one session" do
    orchestrator_name = Module.concat(__MODULE__, :SessionLiveOrchestrator)
    snapshot = static_snapshot()
    transcripts_root = Path.join(Path.dirname(Workflow.workflow_file_path()), "session-live-transcripts")

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      observability_transcripts_root: transcripts_root
    )

    append_test_transcript!(
      %Issue{id: "issue-http", identifier: "MT-HTTP", title: "Session transcript", state: "In Progress"},
      "thread-http",
      base_time: ~U[2026-04-05 10:00:00Z],
      delta: "human readable text",
      turn_id: "turn-session-live"
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/sessions/thread-http")
    assert html =~ "Session Conversation"
    assert html =~ "human readable text"
    assert html =~ "assistant response"
    assert html =~ "(1 events)"
    assert html =~ "/issues/MT-HTTP"
    assert html =~ "/api/v1/sessions/thread-http"
    assert html =~ "/api/v1/sessions/thread-http.ndjson"
  end

  test "session liveview collapses repetitive infrastructure updates" do
    orchestrator_name = Module.concat(__MODULE__, :SessionInfraCondenseOrchestrator)
    snapshot = static_snapshot()
    transcripts_root = Path.join(Path.dirname(Workflow.workflow_file_path()), "session-infra-condense-transcripts")

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      observability_transcripts_root: transcripts_root
    )

    issue = %Issue{id: "issue-http", identifier: "MT-HTTP", title: "Infra collapse", state: "In Progress"}
    session_id = "thread-http-infra"
    base_time = ~U[2026-04-05 11:00:00Z]

    context = %{
      workspace_path: "/tmp/infra-condense",
      session_id: session_id,
      thread_id: session_id,
      turn_id: "turn-infra-condense"
    }

    [
      %{event: :session_started, session_id: session_id, thread_id: session_id, turn_id: "turn-infra-condense", timestamp: base_time},
      %{event: :notification, payload: %{"method" => "mcpServer/startupStatus/updated"}, timestamp: DateTime.add(base_time, 1, :second)},
      %{event: :notification, payload: %{"method" => "mcpServer/startupStatus/updated"}, timestamp: DateTime.add(base_time, 2, :second)},
      %{event: :notification, payload: %{"method" => "mcpServer/startupStatus/updated"}, timestamp: DateTime.add(base_time, 3, :second)},
      %{event: :turn_completed, payload: %{"method" => "turn/completed"}, timestamp: DateTime.add(base_time, 4, :second)}
    ]
    |> Enum.each(fn event ->
      :ok = TranscriptStore.append(issue, context, event)
    end)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/sessions/#{session_id}")
    assert html =~ "mcp startup status updated (3 updates)"
    assert html =~ "Showing"
    assert html =~ "timeline rows from"
  end

  test "session liveview supports toggling between condensed and raw views" do
    orchestrator_name = Module.concat(__MODULE__, :SessionViewToggleOrchestrator)
    snapshot = static_snapshot()
    transcripts_root = Path.join(Path.dirname(Workflow.workflow_file_path()), "session-view-toggle-transcripts")

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      observability_transcripts_root: transcripts_root
    )

    issue = %Issue{id: "issue-http", identifier: "MT-HTTP", title: "View toggle", state: "In Progress"}
    session_id = "thread-http-toggle"
    base_time = ~U[2026-04-05 12:00:00Z]

    context = %{
      workspace_path: "/tmp/view-toggle",
      session_id: session_id,
      thread_id: session_id,
      turn_id: "turn-view-toggle"
    }

    [
      %{event: :session_started, session_id: session_id, thread_id: session_id, turn_id: "turn-view-toggle", timestamp: base_time},
      %{
        event: :notification,
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "first chunk "}
        },
        timestamp: DateTime.add(base_time, 1, :second)
      },
      %{
        event: :notification,
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "second chunk"}
        },
        timestamp: DateTime.add(base_time, 2, :second)
      },
      %{event: :turn_completed, payload: %{"method" => "turn/completed"}, timestamp: DateTime.add(base_time, 3, :second)}
    ]
    |> Enum.each(fn event ->
      :ok = TranscriptStore.append(issue, context, event)
    end)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, condensed_html} = live(build_conn(), "/sessions/#{session_id}")
    assert condensed_html =~ "assistant response:"
    assert condensed_html =~ "(2 events)"
    assert condensed_html =~ "view=raw"

    {:ok, _view, raw_html} = live(build_conn(), "/sessions/#{session_id}?view=raw")
    assert raw_html =~ "agent message streaming: first chunk"
    assert raw_html =~ "agent message streaming: second chunk"
    assert raw_html =~ "view=raw"
    assert raw_html =~ "class=\"issue-link active-toggle\""
    refute raw_html =~ "assistant response:"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"blocked" => 1, "running" => 1, "retrying" => 1}
    assert [%{"issue_identifier" => "MT-BLOCKED", "reason_code" => "approval_required"}] = response.body["blocked"]

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          reason_code: "approval_required",
          summary: "Linear requires approval for this mutation.",
          clearance_hint: "Approve the mutation or adjust the workflow.",
          blocked_at: ~U[2026-04-06 10:11:12Z],
          issue_state: "In Review",
          issue_updated_at: ~U[2026-04-06 10:10:00Z],
          worker_host: "worker-b",
          workspace_path: "/tmp/symphony-blocked",
          retryable: false,
          details: %{"source" => "linear"}
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp append_test_transcript!(issue, session_id, opts \\ []) do
    base_time = Keyword.get(opts, :base_time, ~U[2026-04-05 09:10:11Z])
    delta = Keyword.get(opts, :delta, "rendered")

    context = %{
      workspace_path: Keyword.get(opts, :workspace_path, "/tmp/#{issue.identifier}"),
      worker_host: Keyword.get(opts, :worker_host),
      session_id: session_id,
      thread_id: Keyword.get(opts, :thread_id, session_id),
      turn_id: Keyword.get(opts, :turn_id, "turn-1")
    }

    [
      %{
        event: :session_started,
        session_id: session_id,
        thread_id: context.thread_id,
        turn_id: context.turn_id,
        timestamp: base_time
      },
      %{
        event: :notification,
        payload: %{"method" => "item/agentMessage/delta", "params" => %{"delta" => delta}},
        timestamp: DateTime.add(base_time, 1, :second)
      },
      %{
        event: :turn_completed,
        payload: %{"method" => "turn/completed"},
        timestamp: DateTime.add(base_time, 2, :second)
      }
    ]
    |> Enum.each(fn event ->
      :ok = TranscriptStore.append(issue, context, event)
    end)
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
