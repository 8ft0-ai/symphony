defmodule SymphonyElixir.TranscriptStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TranscriptStore

  test "resolves transcript root from the configured log file location by default" do
    logs_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-transcript-store-log-root-#{System.unique_integer([:positive])}"
      )

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end
    end)

    Application.put_env(:symphony_elixir, :log_file, Path.join(logs_root, "log/symphony.log"))

    assert TranscriptStore.default_root() == Path.join(logs_root, "log/codex_sessions")
    assert TranscriptStore.root() == Path.join(logs_root, "log/codex_sessions")
    assert TranscriptStore.issue_directory("MT/401") == Path.join(logs_root, "log/codex_sessions/issues/MT_401")
    assert TranscriptStore.manifest_path("MT/401") == Path.join(logs_root, "log/codex_sessions/issues/MT_401/manifest.json")
    assert TranscriptStore.relative_session_path("MT/401", %{"file_name" => "thread-1.ndjson"}) == "issues/MT_401/thread-1.ndjson"
  end

  test "honors explicit transcript root config outside the workspace root" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-transcript-store-workspaces-#{System.unique_integer([:positive])}"
      )

    transcripts_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-transcript-store-explicit-root-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      observability_transcripts_root: transcripts_root
    )

    assert TranscriptStore.root() == transcripts_root
    refute String.starts_with?(TranscriptStore.root(), workspace_root <> "/")
  end

  test "appends NDJSON transcript events and updates the per-issue manifest" do
    transcripts_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-transcript-store-append-#{System.unique_integer([:positive])}"
      )

    workspace_path = Path.join(System.tmp_dir!(), "transcript-store-append-workspace")
    timestamp = ~U[2026-04-05 09:10:11.123456Z]

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        observability_transcripts_root: transcripts_root
      )

      issue = %Issue{
        id: "issue-transcript-1",
        identifier: "MT-501",
        title: "Persist transcript",
        state: "In Progress"
      }

      context = %{
        workspace_path: workspace_path,
        worker_host: "worker-a",
        session_id: "thread-501-turn-1",
        thread_id: "thread-501",
        turn_id: "turn-1"
      }

      assert :ok =
               TranscriptStore.append(issue, context, %{
                 event: :session_started,
                 session_id: "thread-501-turn-1",
                 thread_id: "thread-501",
                 turn_id: "turn-1",
                 timestamp: timestamp
               })

      assert :ok =
               TranscriptStore.append(issue, context, %{
                 event: :notification,
                 payload: %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "wrote tests"}},
                 timestamp: DateTime.add(timestamp, 1, :second)
               })

      assert :ok =
               TranscriptStore.append(issue, context, %{
                 event: :turn_completed,
                 payload: %{"method" => "turn/completed", "usage" => %{"total_tokens" => 42}},
                 timestamp: DateTime.add(timestamp, 2, :second)
               })

      manifest = TranscriptStore.manifest_path(issue.identifier) |> File.read!() |> Jason.decode!()
      assert manifest["issue_id"] == issue.id
      assert manifest["issue_identifier"] == issue.identifier
      assert [%{"session_id" => "thread-501-turn-1"} = session] = manifest["sessions"]
      assert session["thread_id"] == "thread-501"
      assert session["turn_id"] == "turn-1"
      assert session["status"] == "completed"
      assert session["event_count"] == 3
      assert session["worker_host"] == "worker-a"
      assert session["workspace_path"] == workspace_path
      assert session["last_event"] == "turn_completed"
      assert session["last_method"] == "turn/completed"
      assert session["last_summary"] =~ "turn completed"

      session_path = TranscriptStore.session_path(issue.identifier, session)
      lines = session_path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 3

      [first_event, second_event, third_event] = Enum.map(lines, &Jason.decode!/1)
      assert first_event["sequence"] == 1
      assert first_event["event"] == "session_started"
      assert first_event["summary"] == "session started (thread-501-turn-1)"
      assert second_event["sequence"] == 2
      assert second_event["method"] == "item/agentMessage/delta"
      assert second_event["worker_host"] == "worker-a"
      assert second_event["workspace_path"] == workspace_path
      assert second_event["data"]["payload"]["method"] == "item/agentMessage/delta"
      assert third_event["sequence"] == 3
      assert third_event["event"] == "turn_completed"
    after
      File.rm_rf(transcripts_root)
    end
  end

  test "accepts ISO8601 string timestamps when appending events" do
    transcripts_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-transcript-store-string-ts-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        observability_transcripts_root: transcripts_root
      )

      issue = %Issue{
        id: "issue-transcript-string-ts",
        identifier: "MT-504",
        title: "Persist transcript from string timestamp",
        state: "In Progress"
      }

      context = %{
        workspace_path: "/tmp/transcript-string-ts",
        worker_host: "worker-string-ts",
        session_id: "thread-504-turn-1",
        thread_id: "thread-504",
        turn_id: "turn-1"
      }

      ts = "2026-04-18T06:58:31.843613Z"

      assert :ok =
               TranscriptStore.append(issue, context, %{
                 event: :session_started,
                 session_id: context.session_id,
                 thread_id: context.thread_id,
                 turn_id: context.turn_id,
                 timestamp: ts
               })

      manifest = TranscriptStore.manifest_path(issue.identifier) |> File.read!() |> Jason.decode!()
      assert [%{"session_id" => "thread-504-turn-1"} = session] = manifest["sessions"]
      assert session["started_at"] == ts

      session_path = TranscriptStore.session_path(issue.identifier, session)
      [line] = session_path |> File.read!() |> String.split("\n", trim: true)
      event = Jason.decode!(line)
      assert event["ts"] == ts
    after
      File.rm_rf(transcripts_root)
    end
  end

  test "reads paginated session events and recent issue events" do
    transcripts_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-transcript-store-pagination-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        observability_transcripts_root: transcripts_root,
        observability_transcript_recent_events_limit: 2
      )

      issue = %Issue{
        id: "issue-transcript-2",
        identifier: "MT-502",
        title: "Paginate transcript",
        state: "In Progress"
      }

      context = %{
        workspace_path: "/tmp/transcript-pagination",
        worker_host: nil,
        session_id: "thread-502-turn-1",
        thread_id: "thread-502",
        turn_id: "turn-1"
      }

      base_time = ~U[2026-04-05 10:00:00.000000Z]

      events = [
        %{
          event: :session_started,
          session_id: context.session_id,
          thread_id: context.thread_id,
          turn_id: context.turn_id,
          timestamp: base_time
        },
        %{
          event: :notification,
          payload: %{"method" => "item/agentMessage/delta"},
          timestamp: DateTime.add(base_time, 1, :second)
        },
        %{
          event: :notification,
          payload: %{"method" => "thread/tokenUsage/updated"},
          timestamp: DateTime.add(base_time, 2, :second)
        },
        %{
          event: :turn_completed,
          payload: %{"method" => "turn/completed"},
          timestamp: DateTime.add(base_time, 3, :second)
        }
      ]

      Enum.each(events, fn event ->
        assert :ok = TranscriptStore.append(issue, context, event)
      end)

      assert {:ok, result} = TranscriptStore.read_session_events(context.session_id, limit: 2, order: :asc)
      assert Enum.map(result.events, & &1["sequence"]) == [1, 2]
      assert result.page["order"] == nil
      assert result.page.order == "asc"
      assert result.page.has_more
      assert result.page.next_cursor == 2

      assert {:ok, next_page} =
               TranscriptStore.read_session_events(context.session_id,
                 limit: 2,
                 order: :asc,
                 cursor: result.page.next_cursor
               )

      assert Enum.map(next_page.events, & &1["sequence"]) == [3, 4]
      refute next_page.page.has_more
      assert next_page.page.next_cursor == nil

      assert {:ok, desc_page} = TranscriptStore.read_session_events(context.session_id, limit: 2, order: :desc)
      assert Enum.map(desc_page.events, & &1["sequence"]) == [4, 3]

      assert {:ok, recent_events} = TranscriptStore.recent_events(issue.identifier)
      assert Enum.map(recent_events, & &1["sequence"]) == [4, 3]
    after
      File.rm_rf(transcripts_root)
    end
  end

  test "disabled transcripts become a no-op and return empty reads" do
    transcripts_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-transcript-store-disabled-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        observability_transcripts_enabled: false,
        observability_transcripts_root: transcripts_root
      )

      issue = %Issue{id: "issue-transcript-disabled", identifier: "MT-503", title: "Disabled transcript", state: "In Progress"}

      assert :ok =
               TranscriptStore.append(issue, %{workspace_path: "/tmp/disabled"}, %{
                 event: :session_started,
                 session_id: "thread-disabled-turn-1",
                 timestamp: ~U[2026-04-05 11:00:00Z]
               })

      refute File.exists?(transcripts_root)
      assert {:ok, []} = TranscriptStore.list_issue_sessions(issue.identifier)
      assert {:ok, []} = TranscriptStore.recent_events(issue.identifier)

      assert {:ok, session_events} = TranscriptStore.read_session_events("thread-disabled-turn-1")
      assert session_events.events == []
      assert session_events.page.has_more == false

      assert {:ok, ndjson} = TranscriptStore.read_session_ndjson("thread-disabled-turn-1")
      assert ndjson.content == ""
    after
      File.rm_rf(transcripts_root)
    end
  end
end
