defmodule SymphonyElixir.RecoveryInspectorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ActionLedger.Action
  alias SymphonyElixir.Codex.RecoveryInspector

  test "settles only an exact persisted thread, cwd, and turn match" do
    root = Path.join(System.tmp_dir!(), "symphony-recovery-inspector-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GH-38")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    action = correlation_action()

    assert {:ok, evidence} =
             RecoveryInspector.inspect(action,
               thread_reader: fn "thread-1", actual_workspace, _opts ->
                 {:ok,
                  %{
                    "id" => "thread-1",
                    "cwd" => actual_workspace,
                    "turns" => [%{"id" => "turn-1"}]
                  }}
               end
             )

    assert evidence.authoritative and evidence.exists
    assert evidence.disposition == "codex_thread_read_exact_match"
  end

  test "does not treat a legacy cached session identifier as provider authority" do
    action = action(%{"workspace_key" => "GH-38", "session_id" => "thread-1-turn-1"})
    assert {:error, {:recovery_correlation_missing, "thread_id"}} = RecoveryInspector.inspect(action)
  end

  test "requires a typed dispatch-host assertion before a fresh read can settle recovery" do
    action =
      correlation_action()
      |> Map.update!(:observed_effect, &Map.delete(&1, "host_assertion"))

    assert {:error, :host_assertion_invalid} = RecoveryInspector.inspect(action)
  end

  test "quarantines malformed provider metadata rather than treating it as absence" do
    root = Path.join(System.tmp_dir!(), "symphony-recovery-malformed-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(Path.join(workspace_root, "GH-38"))
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, :thread_turns_missing} =
             RecoveryInspector.inspect(correlation_action(),
               thread_reader: fn _, workspace, _ -> {:ok, %{"id" => "thread-1", "cwd" => workspace}} end
             )
  end

  test "fails closed for unsupported actions, missing effects, remote host assertions, and bad provider identity" do
    root = Path.join(System.tmp_dir!(), "symphony-recovery-branches-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GH-38")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, :unsupported_recovery_action} =
             RecoveryInspector.inspect(%{correlation_action() | kind: :fork})

    assert {:error, :recovery_correlation_missing} =
             RecoveryInspector.inspect(%{correlation_action() | observed_effect: nil})

    remote_action =
      correlation_action()
      |> Map.update!(:observed_effect, fn effect ->
        Map.put(effect, "host_assertion", %{"type" => "worker_host", "value" => "worker-01"})
      end)

    assert {:ok, %{exists: true}} =
             RecoveryInspector.inspect(remote_action,
               thread_reader: fn _, actual_workspace, worker_host: "worker-01" ->
                 {:ok, %{"id" => "thread-1", "cwd" => actual_workspace, "turns" => [%{"id" => "turn-1"}]}}
               end
             )

    assert {:error, :thread_id_mismatch} =
             RecoveryInspector.inspect(correlation_action(),
               thread_reader: fn _, actual_workspace, _ ->
                 {:ok, %{"id" => "wrong-thread", "cwd" => actual_workspace, "turns" => [%{"id" => "turn-1"}]}}
               end
             )

    assert {:error, :thread_payload_invalid} =
             RecoveryInspector.inspect(correlation_action(), thread_reader: fn _, _, _ -> {:ok, :invalid} end)
  end

  test "authoritative absence is retryable evidence while mismatches fail closed" do
    root = Path.join(System.tmp_dir!(), "symphony-recovery-absence-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GH-38")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    action = correlation_action()

    assert {:ok, %{authoritative: true, exists: false}} =
             RecoveryInspector.inspect(action,
               thread_reader: fn _, _, _ -> {:error, :thread_not_found} end
             )

    assert {:error, :workspace_mismatch} =
             RecoveryInspector.inspect(action,
               thread_reader: fn _, _, _ ->
                 {:ok, %{"id" => "thread-1", "cwd" => "/wrong", "turns" => [%{"id" => "turn-1"}]}}
               end
             )
  end

  defp action(effect) do
    %Action{
      id: "act-1",
      idempotency_key: "key",
      lineage_key: "lineage",
      kind: :task_creation,
      source: %{"issue_identifier" => "GH-38"},
      target: %{"type" => "codex_task"},
      purpose_hash: "hash",
      checkpoint: "checkpoint",
      expected_postcondition: "codex.session_observed",
      policy_fingerprint: "policy",
      state: :uncertain,
      inserted_at: "2026-08-31T00:00:00Z",
      updated_at: "2026-08-31T00:00:00Z",
      observed_effect: effect
    }
  end

  defp correlation_action do
    action(%{
      "workspace_key" => "GH-38",
      "thread_id" => "thread-1",
      "turn_id" => "turn-1",
      "session_correlation_id" => "thread-1-turn-1",
      "host_assertion" => %{"type" => "worker_host", "value" => "local"}
    })
  end
end
