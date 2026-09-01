defmodule SymphonyElixir.ActionLedgerIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ActionLedger
  alias SymphonyElixir.Codex.RecoveryInspector
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

  test "exact logged correlation settles legacy action then dispatches one revised issue through the poll loop" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-ledger-exact-recovery-#{suffix}")
    ledger_path = Path.join(root, "actions.jsonl")
    first_ledger = Module.concat(__MODULE__, "ExactFirstLedger#{suffix}")
    recovered_ledger = Module.concat(__MODULE__, "ExactRecoveredLedger#{suffix}")
    orchestrator = Module.concat(__MODULE__, "ExactRecoveryOrchestrator#{suffix}")
    task_supervisor = Module.concat(__MODULE__, "ExactRecoveryTasks#{suffix}")
    issue_id = "issue-exact-recovery-#{suffix}"
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 60_000)

    stale_intent = %{
      kind: :task_creation,
      source: %{issue_id: issue_id, issue_identifier: "REC-#{suffix}", repository: "github.example/sysmiq/repo", revision: "stale"},
      target: %{type: "codex_task", worker_host: "local"},
      purpose: "orchestrator.dispatch.attempt.0",
      checkpoint: "stale",
      expected_postcondition: "codex.session_observed",
      policy_fingerprint: ActionLedger.policy_fingerprint("exact-recovery-test")
    }

    {:ok, first_pid} = ActionLedger.start_link(name: first_ledger, path: ledger_path, enabled: true)
    assert {:ok, stale_action, :new} = ActionLedger.plan(first_ledger, stale_intent)
    assert {:ok, _} = ActionLedger.transition(first_ledger, stale_action.id, :dispatched)
    GenServer.stop(first_pid)

    {:ok, _recovered_pid} = ActionLedger.start_link(name: recovered_ledger, path: ledger_path, enabled: true)

    assert {:ok, _} =
             ActionLedger.observe_effect(recovered_ledger, stale_action.id, %{
               "thread_id" => "thread-#{suffix}",
               "turn_id" => "turn-#{suffix}",
               "session_correlation_id" => "thread-#{suffix}-turn-#{suffix}",
               "workspace_key" => "REC-#{suffix}",
               "host_assertion" => %{"type" => "worker_host", "value" => "local"}
             })

    File.mkdir_p!(Path.join(root, "workspaces/REC-#{suffix}"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 60_000,
      workspace_root: Path.join(root, "workspaces")
    )

    issue = %Issue{
      id: issue_id,
      identifier: "REC-#{suffix}",
      title: "Revised recovery candidate",
      url: "https://github.example/sysmiq/repo/issues/#{suffix}",
      state: "Todo",
      dispatchable: true,
      updated_at: ~U[2026-09-01 00:00:00Z]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    {:ok, _tasks} = Task.Supervisor.start_link(name: task_supervisor)

    thread_id = "thread-#{suffix}"
    turn_id = "turn-#{suffix}"
    session_id = "#{thread_id}-#{turn_id}"

    inspector = fn action ->
      RecoveryInspector.inspect(action,
        thread_reader: fn actual_thread_id, workspace, _opts ->
          if actual_thread_id == thread_id do
            {:ok, %{"id" => thread_id, "cwd" => workspace, "turns" => [%{"id" => turn_id}]}}
          else
            {:error, :thread_not_found}
          end
        end
      )
    end

    starter = fn supervisor, started_issue, _attempt, _recipient, _host ->
      send(parent, {:worker_started, started_issue.id})

      with {:ok, pid} <- Task.Supervisor.start_child(supervisor, fn -> Process.sleep(:infinity) end) do
        {:ok, pid, %{"worker_host" => nil, "workspace_key" => Workspace.workspace_key(started_issue)}}
      end
    end

    assert {:ok, exact_action} = ActionLedger.get(recovered_ledger, stale_action.id)
    assert {:ok, %{session_id: ^session_id}} = inspector.(exact_action)

    {:ok, _runtime} =
      Orchestrator.start_link(
        name: orchestrator,
        action_ledger: recovered_ledger,
        action_inspector: inspector,
        task_supervisor: task_supervisor,
        worker_starter: starter
      )

    recovered_state = :sys.get_state(orchestrator)
    refute MapSet.member?(recovered_state.claimed, issue_id)
    assert {:ok, settled} = ActionLedger.get(recovered_ledger, stale_action.id)
    assert settled.state == :already_satisfied
    send(orchestrator, :run_poll_cycle)
    assert_receive {:worker_started, ^issue_id}, 1_000

    send(orchestrator, :run_poll_cycle)
    refute_receive {:worker_started, ^issue_id}, 100

    on_exit(fn ->
      for name <- [orchestrator, recovered_ledger, task_supervisor] do
        if pid = Process.whereis(name) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _reason -> :ok
          end
        end
      end

      File.rm_rf(root)
    end)
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

  test "native blocked path records one stalled-goal decision and keeps it claimed" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-ledger-stalled-#{suffix}")
    ledger_path = Path.join(root, "actions.jsonl")
    ledger_name = Module.concat(__MODULE__, "StalledLedger#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "StalledOrchestrator#{suffix}")
    recovered_ledger_name = Module.concat(__MODULE__, "RecoveredStalledLedger#{suffix}")
    recovered_orchestrator_name = Module.concat(__MODULE__, "RecoveredStalledOrchestrator#{suffix}")
    issue_id = "issue-stalled-#{suffix}"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, _ledger} = start_supervised({ActionLedger, name: ledger_name, path: ledger_path, enabled: true})

    {:ok, _orchestrator} =
      start_supervised({Orchestrator, name: orchestrator_name, action_ledger: ledger_name})

    issue = %Issue{
      id: issue_id,
      identifier: "STALL-#{suffix}",
      url: "https://linear.app/sysmiq/issue/#{issue_id}",
      updated_at: ~U[2026-08-31 04:00:00Z]
    }

    state = :sys.get_state(orchestrator_name)
    running_entry = %{issue: issue, identifier: issue.identifier, pid: nil, ref: nil, session_id: "session-#{suffix}"}

    blocked = Orchestrator.stop_and_block_issue_for_test(state, issue_id, running_entry, "codex approval required")
    assert Map.has_key?(blocked.blocked, issue_id)
    assert MapSet.member?(blocked.claimed, issue_id)
    assert is_binary(blocked.blocked[issue_id].goal_action_id)

    action_id = blocked.blocked[issue_id].goal_action_id
    assert {:ok, action} = ActionLedger.get(ledger_name, action_id)
    assert action.state == :needs_input
    assert action.blocker_classification == "goal.stalled"
    assert action.resume_condition =~ "decision.resume."
    assert action.resume_condition =~ ~r/^decision\.resume\.[0-9a-f]{64}$/

    assert :ok = stop_supervised(Orchestrator)
    assert :ok = stop_supervised(ActionLedger)

    {:ok, _recovered_ledger} =
      start_supervised({ActionLedger, name: recovered_ledger_name, path: ledger_path, enabled: true})

    {:ok, _recovered_orchestrator} =
      start_supervised({Orchestrator, name: recovered_orchestrator_name, action_ledger: recovered_ledger_name})

    recovered_state = :sys.get_state(recovered_orchestrator_name)
    assert MapSet.member?(recovered_state.claimed, issue_id)
    refute Map.has_key?(recovered_state.blocked, issue_id)

    assert {:error, :resume_condition_mismatch} =
             Orchestrator.resume_goal(recovered_orchestrator_name, action_id, "decision.resume.wrong")

    assert {:ok, %{action_id: ^action_id}} =
             Orchestrator.resume_goal(recovered_orchestrator_name, action_id, action.resume_condition)

    resumed_state = :sys.get_state(recovered_orchestrator_name)
    refute Map.has_key?(resumed_state.blocked, issue_id)
    refute MapSet.member?(resumed_state.claimed, issue_id)
    assert is_reference(resumed_state.tick_token)
    assert is_integer(resumed_state.next_poll_due_at_ms)
    assert {:ok, resumed_action} = ActionLedger.get(recovered_ledger_name, action_id)
    assert resumed_action.state == :already_satisfied

    assert :ok = stop_supervised(Orchestrator)
    assert :ok = stop_supervised(ActionLedger)

    {:ok, _final_ledger} =
      start_supervised({ActionLedger, name: ledger_name, path: ledger_path, enabled: true})

    {:ok, _final_orchestrator} =
      start_supervised({Orchestrator, name: orchestrator_name, action_ledger: ledger_name})

    refute :sys.get_state(orchestrator_name).claimed |> MapSet.member?(issue_id)

    on_exit(fn -> File.rm_rf(root) end)
  end

  test "startup inspects uncertain action and releases a claim only after authoritative absence" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-ledger-startup-inspect-#{suffix}")
    path = Path.join(root, "actions.jsonl")
    ledger_name = Module.concat(__MODULE__, "StartupLedger#{suffix}")
    recovered_ledger_name = Module.concat(__MODULE__, "RecoveredStartupLedger#{suffix}")
    runtime_name = Module.concat(__MODULE__, "RecoveredStartupRuntime#{suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "RecoveredStartupTasks#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "StartupOrchestrator#{suffix}")
    issue_id = "issue-startup-inspect-#{suffix}"

    intent = %{
      kind: :task_creation,
      source: %{issue_id: issue_id, task_id: "task-#{suffix}", revision: "rev-1"},
      target: %{type: "codex_task", worker_host: "local"},
      purpose: "startup-inspection",
      checkpoint: "rev-1",
      expected_postcondition: "codex.session_observed",
      policy_fingerprint: ActionLedger.policy_fingerprint("startup-test")
    }

    {:ok, _first_pid} = start_supervised({ActionLedger, name: ledger_name, path: path, enabled: true})
    assert {:ok, action, :new} = ActionLedger.plan(ledger_name, intent)
    assert {:ok, _} = ActionLedger.transition(ledger_name, action.id, :dispatched)
    assert :ok = stop_supervised(ActionLedger)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, _} =
      SymphonyElixir.AgentRuntimeSupervisor.start_link(
        name: runtime_name,
        task_supervisor_name: task_supervisor_name,
        orchestrator_name: orchestrator_name,
        action_ledger_enabled: true,
        action_ledger_name: recovered_ledger_name,
        action_ledger_path: path,
        action_inspector: fn _action ->
          {:ok, %{provider: "codex", authoritative: true, exists: false}}
        end
      )

    assert :sys.get_state(orchestrator_name).claimed |> MapSet.member?(issue_id) == false
    assert {:ok, recovered} = ActionLedger.get(recovered_ledger_name, action.id)
    assert recovered.state == :planned
    on_exit(fn -> File.rm_rf(root) end)
  end

  test "enabled ledger records a normal worker exit without crashing the orchestrator" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-ledger-worker-exit-#{suffix}")
    path = Path.join(root, "actions.jsonl")
    ledger_name = Module.concat(__MODULE__, "WorkerExitLedger#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "WorkerExitOrchestrator#{suffix}")
    issue_id = "issue-worker-exit-#{suffix}"
    ref = make_ref()

    intent = %{
      kind: :task_creation,
      source: %{issue_id: issue_id, task_id: "task-#{suffix}", revision: "rev-1"},
      target: %{type: "codex_task", worker_host: "local"},
      purpose: "worker-exit",
      checkpoint: "rev-1",
      expected_postcondition: "codex.session_observed",
      policy_fingerprint: ActionLedger.policy_fingerprint("worker-exit-test")
    }

    {:ok, _} = start_supervised({ActionLedger, name: ledger_name, path: path, enabled: true})
    assert {:ok, action, :new} = ActionLedger.plan(ledger_name, intent)
    assert {:ok, _} = ActionLedger.transition(ledger_name, action.id, :dispatched)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, _} = start_supervised({Orchestrator, name: orchestrator_name, action_ledger: ledger_name})

    issue = %Issue{id: issue_id, identifier: "EXIT-#{suffix}", url: "https://linear.app/sysmiq/issue/#{issue_id}"}

    :sys.replace_state(orchestrator_name, fn state ->
      running_entry = %{
        issue: issue,
        identifier: issue.identifier,
        action_id: action.id,
        ref: ref,
        session_id: "session-#{suffix}",
        started_at: DateTime.utc_now()
      }

      %{state | running: %{issue_id => running_entry}, claimed: MapSet.put(state.claimed, issue_id)}
    end)

    send(orchestrator_name, {:DOWN, ref, :process, self(), :normal})
    state = :sys.get_state(orchestrator_name)

    assert Process.alive?(Process.whereis(orchestrator_name))
    refute Map.has_key?(state.running, issue_id)
    assert {:ok, exited} = ActionLedger.get(ledger_name, action.id)
    assert exited.state == :retryable_failure
    on_exit(fn -> File.rm_rf(root) end)
  end
end
