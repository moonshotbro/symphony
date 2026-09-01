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

  test "fails closed when the persisted thread has no matching turn" do
    root = Path.join(System.tmp_dir!(), "symphony-recovery-turn-mismatch-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GH-38")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, :turn_id_mismatch} =
             RecoveryInspector.inspect(correlation_action(),
               thread_reader: fn _, actual_workspace, _ ->
                 {:ok,
                  %{
                    "id" => "thread-1",
                    "cwd" => actual_workspace,
                    "turns" => [%{"id" => "different-turn"}]
                  }}
               end
             )
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

  test "fails closed with a typed error when a persisted turn item is not a map" do
    root = Path.join(System.tmp_dir!(), "symphony-recovery-malformed-turn-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(Path.join(workspace_root, "GH-38"))
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, :thread_turn_payload_invalid} =
             RecoveryInspector.inspect(correlation_action(),
               thread_reader: fn _, workspace, _ ->
                 {:ok, %{"id" => "thread-1", "cwd" => workspace, "turns" => ["malformed"]}}
               end
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

  test "legacy zero-turn recovery compensates only one exact empty interrupted session" do
    root = Path.join(System.tmp_dir!(), "symphony-legacy-zero-turn-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GH-38")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    candidate = %{
      "id" => "thread-legacy",
      "status" => %{"type" => "notLoaded"},
      "usage" => %{"totalTokens" => 0},
      "turns" => [
        %{
          "id" => "turn-legacy",
          "status" => "interrupted",
          "itemsView" => "full",
          "items" => [],
          "usage" => %{"totalTokens" => 0}
        }
      ]
    }

    assert {:ok, evidence} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil ->
                 {:ok, [Map.put(candidate, "cwd", actual_workspace)]}
               end
             )

    assert evidence == %{
             provider: "codex",
             authoritative: true,
             exists: true,
             workspace_key: "GH-38",
             disposition: "legacy_zero_turn_compensated"
           }

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn _actual_workspace, worker_host: nil -> {:ok, []} end
             )

    assert {:error, :legacy_zero_turn_ambiguous} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil ->
                 exact = Map.put(candidate, "cwd", actual_workspace)
                 {:ok, [exact, Map.put(exact, "id", "other")]}
               end
             )

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn _actual_workspace, worker_host: nil -> {:ok, [Map.put(candidate, "cwd", "/wrong")]} end
             )

    non_zero = put_in(candidate, ["turns", Access.at(0), "items"], [%{"type" => "agentMessage"}])

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil -> {:ok, [Map.put(non_zero, "cwd", actual_workspace)]} end
             )

    unloaded_items = put_in(candidate, ["turns", Access.at(0), "itemsView"], "notLoaded")

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil ->
                 {:ok, [Map.put(unloaded_items, "cwd", actual_workspace)]}
               end
             )

    missing_thread_usage = Map.delete(candidate, "usage")

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil ->
                 {:ok, [Map.put(missing_thread_usage, "cwd", actual_workspace)]}
               end
             )

    missing_turn_usage = update_in(candidate, ["turns", Access.at(0)], &Map.delete(&1, "usage"))

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil ->
                 {:ok, [Map.put(missing_turn_usage, "cwd", actual_workspace)]}
               end
             )

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil ->
                 empty_usage = put_in(candidate, ["turns", Access.at(0), "usage"], %{})
                 {:ok, [Map.merge(empty_usage, %{"cwd" => actual_workspace, "usage" => %{}})]}
               end
             )

    nonzero_usage = put_in(candidate, ["turns", Access.at(0), "usage", "totalTokens"], 1)

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil ->
                 {:ok, [Map.put(nonzero_usage, "cwd", actual_workspace)]}
               end
             )

    missing_thread_id = Map.delete(candidate, "id")

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil ->
                 {:ok, [Map.put(missing_thread_id, "cwd", actual_workspace)]}
               end
             )

    missing_turn_id = update_in(candidate, ["turns", Access.at(0)], &Map.delete(&1, "id"))

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil ->
                 {:ok, [Map.put(missing_turn_id, "cwd", actual_workspace)]}
               end
             )

    wrong_host = %{legacy_action() | target: %{"type" => "codex_task", "worker_host" => ""}}
    assert {:error, :legacy_host_invalid} = RecoveryInspector.inspect(wrong_host)

    remote_host = %{legacy_action() | target: %{"type" => "codex_task", "worker_host" => "worker-01"}}

    assert {:ok, %{disposition: "legacy_zero_turn_compensated"}} =
             RecoveryInspector.inspect(remote_host,
               thread_lister: fn actual_workspace, worker_host: "worker-01" ->
                 {:ok, [Map.put(candidate, "cwd", actual_workspace)]}
               end
             )

    local_host = %{legacy_action() | target: %{"type" => "codex_task", "worker_host" => "local"}}

    assert {:ok, %{disposition: "legacy_zero_turn_compensated"}} =
             RecoveryInspector.inspect(local_host,
               thread_lister: fn actual_workspace, worker_host: nil ->
                 {:ok, [Map.put(candidate, "cwd", actual_workspace)]}
               end
             )

    assert {:error, :legacy_recovery_not_applicable} =
             RecoveryInspector.inspect(%{legacy_action() | target: nil})

    assert {:error, :legacy_host_invalid} =
             RecoveryInspector.inspect(%{legacy_action() | target: %{}})

    assert {:error, :legacy_thread_list_invalid} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn _actual_workspace, worker_host: nil -> {:ok, :invalid} end
             )

    assert {:error, :legacy_zero_turn_not_found} =
             RecoveryInspector.inspect(legacy_action(),
               thread_lister: fn actual_workspace, worker_host: nil ->
                 {:ok, [:invalid, Map.merge(candidate, %{"cwd" => actual_workspace, "status" => "active"})]}
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

  defp legacy_action do
    action(%{"workspace_key" => "GH-38", "disposition" => "restart_reconciliation_required"})
  end
end
