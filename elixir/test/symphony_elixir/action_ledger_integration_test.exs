defmodule SymphonyElixir.ActionLedgerIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ActionLedger
  alias SymphonyElixir.Config.Schema

  test "action ledger is disabled by default and preserves the existing runtime shape" do
    suffix = System.unique_integer([:positive])
    runtime_name = Module.concat(__MODULE__, "DisabledRuntime#{suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "DisabledTasks#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "DisabledOrchestrator#{suffix}")
    ledger_name = Module.concat(__MODULE__, "DisabledLedger#{suffix}")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    assert {:ok, _runtime} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name,
               action_ledger_name: ledger_name
             )

    refute Process.whereis(ledger_name)
    assert :sys.get_state(orchestrator_name).action_ledger == nil
  end

  test "enabled runtime starts the ledger before the orchestrator and injects it" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-ledger-runtime-#{suffix}")
    ledger_path = Path.join(root, "actions.jsonl")
    runtime_name = Module.concat(__MODULE__, "EnabledRuntime#{suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "EnabledTasks#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "EnabledOrchestrator#{suffix}")
    ledger_name = Module.concat(__MODULE__, "EnabledLedger#{suffix}")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    assert {:ok, _runtime} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name,
               action_ledger_enabled: true,
               action_ledger_name: ledger_name,
               action_ledger_path: ledger_path
             )

    on_exit(fn -> File.rm_rf(root) end)

    assert is_pid(Process.whereis(ledger_name))
    assert ActionLedger.enabled?(ledger_name)
    assert :sys.get_state(orchestrator_name).action_ledger == ledger_name
  end

  test "restart recovery claims an uncertain task action and prevents blind redispatch" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-ledger-recovery-#{suffix}")
    ledger_path = Path.join(root, "actions.jsonl")
    first_ledger = Module.concat(__MODULE__, "FirstLedger#{suffix}")
    recovered_ledger = Module.concat(__MODULE__, "RecoveredLedger#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "RecoveryOrchestrator#{suffix}")
    issue_id = "issue-recovery-#{suffix}"

    intent = %{
      kind: :task_creation,
      source: %{
        issue_id: issue_id,
        issue_identifier: "REC-#{suffix}",
        repository: "github.example/sysmiq/repo",
        revision: "checkpoint-1"
      },
      target: %{type: "codex_task", worker_host: "local"},
      purpose: "orchestrator.dispatch.attempt.0",
      checkpoint: "checkpoint-1",
      expected_postcondition: "codex.session_observed",
      policy_fingerprint: ActionLedger.policy_fingerprint("test-policy-v1")
    }

    assert {:ok, first_pid} =
             ActionLedger.start_link(name: first_ledger, path: ledger_path, enabled: true)

    assert {:ok, action, :new} = ActionLedger.plan(first_ledger, intent)

    assert {:ok, _dispatched} =
             ActionLedger.transition(first_ledger, action.id, :dispatched, %{
               "workspace_key" => "REC-#{suffix}",
               "session_id" => "session-recovery-#{suffix}",
               "disposition" => "worker_spawned"
             })

    GenServer.stop(first_pid)

    assert {:ok, _recovered_pid} =
             ActionLedger.start_link(name: recovered_ledger, path: ledger_path, enabled: true)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    assert {:ok, _orchestrator_pid} =
             Orchestrator.start_link(
               name: orchestrator_name,
               action_ledger: recovered_ledger
             )

    on_exit(fn ->
      File.rm_rf(root)
    end)

    assert {:ok, recovered_action} = ActionLedger.get(recovered_ledger, action.id)
    assert recovered_action.state == :uncertain
    assert recovered_action.source["issue_id"] == issue_id
    assert recovered_action.observed_effect["workspace_key"] == "REC-#{suffix}"
    assert recovered_action.observed_effect["session_id"] == "session-recovery-#{suffix}"
    assert MapSet.member?(:sys.get_state(orchestrator_name).claimed, issue_id)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert snapshot.action_ledger.counts.pending == 1

    assert [%{action_id: action_id, state: :uncertain, issue_id: ^issue_id}] =
             snapshot.action_ledger.unresolved

    assert action_id == action.id
  end

  test "configuration requires an explicit durable path when enabling the ledger" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"action_ledger" => %{"enabled" => true}})

    assert message =~ "action_ledger.path"

    assert {:ok, settings} =
             Schema.parse(%{
               "workspace" => %{"root" => "/tmp/symphony-workspaces"},
               "action_ledger" => %{
                 "enabled" => true,
                 "path" => "/var/lib/symphony/action-ledger.jsonl"
               }
             })

    assert settings.action_ledger.enabled
    assert settings.action_ledger.path == "/var/lib/symphony/action-ledger.jsonl"

    env_name = "SYMPHONY_TEST_MISSING_LEDGER_PATH"
    previous = System.get_env(env_name)
    System.delete_env(env_name)

    on_exit(fn -> restore_env(env_name, previous) end)

    assert {:error, {:invalid_workflow_config, env_message}} =
             Schema.parse(%{
               "action_ledger" => %{"enabled" => true, "path" => "$#{env_name}"}
             })

    assert env_message =~ "environment reference must resolve"

    System.put_env(env_name, "/var/lib/symphony/env-action-ledger.jsonl")

    assert {:ok, env_settings} =
             Schema.parse(%{
               "action_ledger" => %{"enabled" => true, "path" => "$#{env_name}"}
             })

    assert env_settings.action_ledger.path == "/var/lib/symphony/env-action-ledger.jsonl"
  end
end
