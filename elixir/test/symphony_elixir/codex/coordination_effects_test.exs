defmodule SymphonyElixir.Codex.CoordinationEffectsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ActionLedger, Codex.CoordinationEffects}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-coordination-effects-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, ledger} = ActionLedger.start_link(path: Path.join(root, "ledger.jsonl"))
    %{ledger: ledger, root: root}
  end

  test "only native App Server thread forks are marked supported" do
    assert CoordinationEffects.capability(:fork) == :supported
    assert CoordinationEffects.capability(:task_messaging) == :unsupported
    assert CoordinationEffects.capability(:automation) == :unsupported
    assert CoordinationEffects.capability(:handoff) == :unsupported
  end

  test "desktop-only effect records a durable fail-closed outcome", %{ledger: ledger} do
    assert {:error, {:provider_capability_unsupported, :task_messaging}} =
             CoordinationEffects.reject_unsupported(ledger, intent(:task_messaging), :task_messaging)

    assert {:ok, action, :existing} = ActionLedger.plan(ledger, intent(:task_messaging))
    assert action.state == :preflight_rejected
    assert action.observed_effect == %{"disposition" => "provider_capability_unsupported"}
  end

  test "typed production boundary routes task creation and rejects unsupported effects", %{ledger: ledger} do
    task_creation = %{intent(:fork) | kind: :task_creation, expected_postcondition: "codex.session_observed"}

    assert {:ok, :worker_started, action} =
             CoordinationEffects.dispatch(ledger, task_creation, :task_creation, fn ->
               {:ok, :worker_started, %{"disposition" => "worker_spawned"}}
             end)

    assert action.state == :succeeded

    assert {:error, {:provider_capability_unsupported, :handoff}} =
             CoordinationEffects.dispatch(ledger, intent(:handoff), :handoff, :no_effect)
  end

  test "fork adapter rejects an intent that cannot bind a source thread", %{ledger: ledger} do
    invalid = Map.delete(intent(:fork), :target)
    assert {:error, :fork_intent_invalid} = CoordinationEffects.dispatch_fork(ledger, invalid, "/tmp")
    assert {:error, :fork_intent_invalid} = CoordinationEffects.dispatch_fork(ledger, :invalid, "/tmp")
  end

  test "fork recovery fails closed for missing source, wrong action kind, unavailable provider, and bad evidence", %{
    ledger: ledger,
    root: root
  } do
    workspace = prepare_provider!(root)
    assert {:ok, action, :new} = ActionLedger.plan(ledger, intent(:fork))
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :dispatched)

    assert {:ok, action} =
             ActionLedger.transition(ledger, action.id, :uncertain, %{
               "fork_thread_id" => "thread-child"
             })

    assert {:ok, missing_source} =
             CoordinationEffects.inspect_recovered_fork(%{action | target: %{}}, workspace)

    assert missing_source["disposition"] == "source_thread_missing"

    assert {:error, :fork_action_required} =
             CoordinationEffects.inspect_recovered_fork(%{action | kind: :automation}, workspace)

    assert {:ok, unavailable} = CoordinationEffects.inspect_recovered_fork(action, "/tmp")
    assert unavailable["disposition"] == "provider_unavailable"

    wrong_workspace = prepare_provider!(root, :wrong_fork)

    assert {:ok, mismatch} = CoordinationEffects.inspect_recovered_fork(action, wrong_workspace)
    assert mismatch["disposition"] == "fork_postcondition_mismatch"

    read_error_workspace = prepare_provider!(root, :read_error)

    assert {:ok, read_failed} =
             CoordinationEffects.inspect_recovered_fork(action, read_error_workspace)

    assert read_failed["disposition"] == "fork_read_failed"
  end

  test "fork dispatch returns a retryable provider postcondition failure", %{ledger: ledger, root: root} do
    workspace = prepare_provider!(root, :wrong_fork)

    assert {:error, {:invalid_thread_fork_response, _response}} =
             CoordinationEffects.dispatch_fork(ledger, intent(:fork), workspace)
  end

  test "fork dispatch uses the provider source and child identities and deduplicates", %{
    ledger: ledger,
    root: root
  } do
    workspace = prepare_provider!(root)

    assert {:ok, fork_thread, action} = CoordinationEffects.dispatch_fork(ledger, intent(:fork), workspace)
    assert action.state == :succeeded
    assert fork_thread["id"] == "thread-child"
    assert action.observed_effect["thread_id"] == "thread-source"
    assert action.observed_effect["fork_thread_id"] == "thread-child"

    assert {:already_satisfied, replay} =
             CoordinationEffects.dispatch_fork(ledger, intent(:fork), workspace)

    assert replay.id == action.id
  end

  test "fork recovery inspects a recorded child and quarantines an unrecorded child", %{
    ledger: ledger,
    root: root
  } do
    workspace = prepare_provider!(root)

    assert {:ok, recorded, :new} = ActionLedger.plan(ledger, intent(:fork))
    assert {:ok, _} = ActionLedger.transition(ledger, recorded.id, :dispatched)

    assert {:ok, recorded} =
             ActionLedger.transition(ledger, recorded.id, :uncertain, %{
               "thread_id" => "thread-source",
               "fork_thread_id" => "thread-child"
             })

    assert {:ok, evidence} = CoordinationEffects.inspect_recovered_fork(recorded, workspace)
    assert evidence["authoritative"]
    assert evidence["exists"]
    assert evidence["fork_thread_id"] == "thread-child"

    assert {:ok, unrecorded, :new} =
             ActionLedger.plan(ledger, %{intent(:fork) | checkpoint: "revision-unrecorded"})

    assert {:ok, _} = ActionLedger.transition(ledger, unrecorded.id, :dispatched)
    assert {:ok, unrecorded} = ActionLedger.transition(ledger, unrecorded.id, :uncertain)
    assert {:ok, unknown} = CoordinationEffects.inspect_recovered_fork(unrecorded, workspace)
    refute unknown["authoritative"]
    assert unknown["disposition"] == "fork_identity_unrecorded"
  end

  test "fork dispatch inspects an uncertain recorded fork before deduplicating", %{ledger: ledger, root: root} do
    workspace = prepare_provider!(root)
    assert {:ok, action, :new} = ActionLedger.plan(ledger, intent(:fork))
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :dispatched)

    assert {:ok, _} =
             ActionLedger.transition(ledger, action.id, :uncertain, %{
               "thread_id" => "thread-source",
               "fork_thread_id" => "thread-child"
             })

    assert {:already_satisfied, action} = CoordinationEffects.dispatch_fork(ledger, intent(:fork), workspace)
    assert action.state == :already_satisfied
  end

  test "lost fork response becomes uncertain and cannot replay a duplicate fork", %{ledger: ledger, root: root} do
    workspace = prepare_provider!(root, :timeout)
    trace_file = Path.join(root, "fork-timeout.trace")

    assert {:error, :response_timeout} =
             CoordinationEffects.dispatch_fork(ledger, intent(:fork), workspace)

    assert File.read!(trace_file) == "thread/fork\n"
    assert {:ok, action, :existing} = ActionLedger.plan(ledger, intent(:fork))
    assert action.state == :uncertain
    action_id = action.id

    assert {:error, {:uncertain_action_quarantined, ^action_id}} =
             CoordinationEffects.dispatch_fork(ledger, intent(:fork), workspace)

    trace = File.read!(trace_file)
    assert trace == "thread/fork\n"
  end

  defp intent(kind) do
    %{
      kind: kind,
      source: %{issue_id: "issue-39", session_id: "session-source"},
      target: %{type: "codex_thread", id: "thread-source"},
      purpose: "coordinate-one-test-effect",
      checkpoint: "revision-39",
      expected_postcondition: if(kind == :fork, do: "codex.thread_forked", else: "desktop.effect_recorded"),
      policy_fingerprint: ActionLedger.policy_fingerprint("test-policy-v1")
    }
  end

  defp prepare_provider!(root, mode \\ :valid) do
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "MT-CONTROL-#{mode}")
    codex_binary = Path.join(root, "fake-codex-#{mode}")
    File.mkdir_p!(workspace)

    child_read_response = child_read_response(mode)

    timeout_trace = Path.join(root, "fork-timeout.trace")

    File.write!(codex_binary, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/read"'*'thread-child'*) printf '%s\\n' '#{child_read_response}' ;;
        *'"method":"thread/read"'*) printf '%s\\n' '{"id":10,"result":{"thread":{"id":"thread-source","sessionId":"session-root"}}}' ;;
        *'"method":"thread/fork"'*) #{fork_command(mode, timeout_trace)} ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      codex_read_timeout_ms: if(mode == :timeout, do: 1_000, else: 5_000)
    )

    workspace
  end

  defp child_read_response(:wrong_fork),
    do: ~s({"id":10,"result":{"thread":{"id":"thread-child","sessionId":"session-root","forkedFromId":"thread-other"}}})

  defp child_read_response(:read_error), do: ~s({"id":10,"error":{"message":"read failed"}})

  defp child_read_response(_mode),
    do: ~s({"id":10,"result":{"thread":{"id":"thread-child","sessionId":"session-root","forkedFromId":"thread-source"}}})

  defp fork_command(:timeout, trace_file), do: "printf '%s\\n' 'thread/fork' >> '#{trace_file}'"

  defp fork_command(:wrong_fork, _trace_file),
    do: "printf '%s\\n' '{\"id\":11,\"result\":{\"thread\":{\"id\":\"thread-child\",\"sessionId\":\"session-root\",\"forkedFromId\":\"thread-other\"}}}'"

  defp fork_command(_mode, _trace_file),
    do: "printf '%s\\n' '{\"id\":11,\"result\":{\"thread\":{\"id\":\"thread-child\",\"sessionId\":\"session-root\",\"forkedFromId\":\"thread-source\"}}}'"
end
