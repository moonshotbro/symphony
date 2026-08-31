defmodule SymphonyElixir.ActionLedgerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ActionLedger, CoordinationAdapter}

  @transition_table %{
    planned: ~w(preflight_rejected dispatched quarantined needs_input terminal_failure)a,
    dispatched: ~w(succeeded already_satisfied uncertain retryable_failure compensated quarantined needs_input terminal_failure)a,
    uncertain: ~w(succeeded already_satisfied retryable_failure compensated quarantined needs_input terminal_failure)a,
    retryable_failure: ~w(planned quarantined needs_input terminal_failure)a,
    quarantined: ~w(planned needs_input terminal_failure)a,
    needs_input: ~w(planned quarantined terminal_failure)a
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-action-ledger-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, path: Path.join(root, "action-ledger.jsonl")}
  end

  test "canonical intent is idempotent and changed checkpoint supersedes", %{path: path} do
    ledger = start_ledger(path)

    left = intent(%{source: %{issue_id: "issue-1", repository: "repo"}})
    right = intent(%{source: %{"repository" => "repo", "issue_id" => "issue-1"}})

    assert {:ok, first, :new} = ActionLedger.plan(ledger, left)
    assert {:ok, replay, :existing} = ActionLedger.plan(ledger, right)
    assert replay.id == first.id
    assert replay.idempotency_key == first.idempotency_key

    changed = put_in(left, [:checkpoint], "revision-2")
    assert {:ok, replacement, :new} = ActionLedger.plan(ledger, changed)
    assert replacement.id != first.id
    assert replacement.supersedes == first.id

    assert {:ok, changed_purpose, :new} =
             ActionLedger.plan(ledger, %{left | purpose: "dispatch-corrected-issue"})

    assert changed_purpose.id not in [first.id, replacement.id]

    assert {:ok, changed_target, :new} =
             ActionLedger.plan(ledger, put_in(left, [:target, :worker_host], "worker-2"))

    assert changed_target.id not in [first.id, replacement.id, changed_purpose.id]
  end

  test "every declared transition is accepted and undeclared transitions fail", %{root: root} do
    Enum.each(@transition_table, fn {from, destinations} ->
      Enum.each(destinations, fn destination ->
        path = Path.join(root, "#{from}-#{destination}.jsonl")
        ledger = start_ledger(path)
        assert {:ok, action, :new} = ActionLedger.plan(ledger, intent())
        action = reach_state(ledger, action, from)
        assert {:ok, transitioned} = ActionLedger.transition(ledger, action.id, destination)
        assert transitioned.state == destination
        GenServer.stop(ledger)
      end)
    end)

    ledger = start_ledger(Path.join(root, "invalid.jsonl"))
    assert {:ok, action, :new} = ActionLedger.plan(ledger, intent())

    assert {:error, {:invalid_transition, :planned, :succeeded}} =
             ActionLedger.transition(ledger, action.id, :succeeded)
  end

  test "terminal records are immutable and changed intent creates a linked correction", %{path: path} do
    ledger = start_ledger(path)
    assert {:ok, action, :new} = ActionLedger.plan(ledger, intent())
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :preflight_rejected)

    assert {:error, {:invalid_transition, :preflight_rejected, :planned}} =
             ActionLedger.transition(ledger, action.id, :planned)

    assert {:error, :terminal_action_immutable} =
             ActionLedger.observe_effect(ledger, action.id, %{"disposition" => "changed"})

    assert {:ok, correction, :new} =
             ActionLedger.plan(ledger, intent(%{purpose: "corrected-dispatch"}))

    assert correction.supersedes == action.id
  end

  test "restart converts dispatched action to uncertain and prevents blind redispatch", %{path: path} do
    ledger = start_ledger(path)
    probe = intent(%{source: %{issue_id: "issue-restart", session_id: "session-1"}})
    assert {:ok, action, :new} = ActionLedger.plan(ledger, probe)
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :dispatched)
    GenServer.stop(ledger)

    recovered = start_ledger(path)
    assert {:ok, uncertain} = ActionLedger.get(recovered, action.id)
    assert uncertain.state == :uncertain
    assert uncertain.source["issue_id"] == "issue-restart"
    assert uncertain.source["session_id"] == "session-1"
    parent = self()
    action_id = action.id

    assert {:error, {:uncertain_action, ^action_id}} =
             CoordinationAdapter.dispatch(recovered, probe, fn ->
               send(parent, :duplicate_dispatched)
               {:ok, :duplicate, %{}}
             end)

    refute_received :duplicate_dispatched
    assert %{pending: [pending]} = ActionLedger.reconcile(recovered)
    assert pending.id == action.id
  end

  test "successful adapter dispatch is replay-safe and records only bounded effects", %{path: path} do
    ledger = start_ledger(path)
    parent = self()
    probe = intent()

    assert {:ok, :worker_started, completed} =
             CoordinationAdapter.dispatch(ledger, probe, fn ->
               send(parent, :effect_called)
               {:ok, :worker_started, %{"thread_id" => "thread-1", "disposition" => "started"}}
             end)

    assert_received :effect_called
    assert completed.state == :succeeded

    assert completed.observed_effect == %{
             "disposition" => "started",
             "thread_id" => "thread-1"
           }

    assert {:already_satisfied, replay} =
             CoordinationAdapter.dispatch(ledger, probe, fn ->
               send(parent, :duplicate_dispatched)
               {:ok, :duplicate, %{}}
             end)

    assert replay.id == completed.id
    refute_received :duplicate_dispatched
  end

  test "effect crash remains dispatched until restart marks it uncertain", %{path: path} do
    ledger = start_ledger(path)
    probe = intent(%{checkpoint: "crash-checkpoint"})

    assert_raise RuntimeError, "injected dispatch crash", fn ->
      CoordinationAdapter.dispatch(ledger, probe, fn ->
        raise "injected dispatch crash"
      end)
    end

    assert {:ok, action, :existing} = ActionLedger.plan(ledger, probe)
    assert action.state == :dispatched
    GenServer.stop(ledger)

    recovered = start_ledger(path)
    assert {:ok, uncertain} = ActionLedger.get(recovered, action.id)
    assert uncertain.state == :uncertain
  end

  test "known failure is retryable without duplicate effect", %{path: path} do
    ledger = start_ledger(path)
    probe = intent(%{checkpoint: "retry-checkpoint"})

    assert {:error, :capacity_exhausted} =
             CoordinationAdapter.dispatch(ledger, probe, fn ->
               {:error, :capacity_exhausted, :retryable_failure}
             end)

    assert {:ok, failed, :existing} = ActionLedger.plan(ledger, probe)
    assert failed.state == :retryable_failure

    assert {:ok, :worker_started, succeeded} =
             CoordinationAdapter.dispatch(ledger, probe, fn ->
               {:ok, :worker_started, %{"disposition" => "started"}}
             end)

    assert succeeded.state == :succeeded
    assert succeeded.id == failed.id
  end

  test "corrupt and truncated storage fail closed", %{root: root} do
    corrupt = Path.join(root, "corrupt.jsonl")
    truncated = Path.join(root, "truncated.jsonl")
    File.write!(corrupt, "not-json\n")
    File.write!(truncated, ~s({"schema":"symphony.action-ledger.v1"}))

    assert {:error, {:ledger_corrupt, _child}} = start_ledger_result(corrupt)
    assert {:error, {:ledger_truncated, _child}} = start_ledger_result(truncated)
  end

  test "unavailable storage rejects mutation while a loaded ledger remains inspectable", %{
    root: root
  } do
    state_dir = Path.join(root, "state")
    File.mkdir_p!(state_dir)
    ledger = start_ledger(Path.join(state_dir, "ledger.jsonl"))
    File.rename!(state_dir, Path.join(root, "state-backup"))
    File.write!(state_dir, "occupied")

    assert {:error, {:ledger_write_failed, :enotdir}} = ActionLedger.plan(ledger, intent())

    assert %{pending: [], retryable: [], quarantined: [], needs_input: []} =
             ActionLedger.reconcile(ledger)
  end

  test "sensitive or arbitrary fields never enter the ledger", %{path: path} do
    ledger = start_ledger(path)

    assert {:error, {:field_not_allowed, "prompt_body"}} =
             ActionLedger.plan(
               ledger,
               intent(%{source: %{issue_id: "issue-1", prompt_body: "secret"}})
             )

    assert {:ok, action, :new} = ActionLedger.plan(ledger, intent())

    assert {:error, {:field_not_allowed, "credential"}} =
             ActionLedger.transition(ledger, action.id, :dispatched, %{
               credential: "secret"
             })

    encoded = File.read!(path)
    refute encoded =~ "secret"
    refute encoded =~ "dispatch-current-issue"
  end

  test "reconciler returns each operator disposition deterministically", %{path: path} do
    ledger = start_ledger(path)

    pending = plan_with_checkpoint(ledger, "pending")
    retryable = plan_with_checkpoint(ledger, "retryable")
    quarantine = plan_with_checkpoint(ledger, "quarantine")
    input = plan_with_checkpoint(ledger, "input")

    assert {:ok, _} = ActionLedger.transition(ledger, retryable.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, retryable.id, :retryable_failure)
    assert {:ok, _} = ActionLedger.transition(ledger, quarantine.id, :quarantined)
    assert {:ok, _} = ActionLedger.transition(ledger, input.id, :needs_input)

    result = ActionLedger.reconcile(ledger)
    assert Enum.map(result.pending, & &1.id) == [pending.id]
    assert Enum.map(result.retryable, & &1.id) == [retryable.id]
    assert Enum.map(result.quarantined, & &1.id) == [quarantine.id]
    assert Enum.map(result.needs_input, & &1.id) == [input.id]
  end

  test "stalled goal decisions deduplicate and resume only on their named condition", %{path: path} do
    ledger = start_ledger(path)

    stalled =
      intent(%{
        kind: :task_messaging,
        source: %{goal_id: "goal-stalled-1", task_id: "task-lead-1"},
        target: %{type: "goal_owner", id: "goal-stalled-1"},
        purpose: "request-bounded-contract-choice",
        checkpoint: "decision-revision-1",
        expected_postcondition: "goal.decision_recorded",
        blocker_classification: "goal.stalled",
        resume_condition: "decision.customer_contract_selected"
      })

    assert {:ok, action, :new} = ActionLedger.plan(ledger, stalled)
    assert {:ok, waiting} = ActionLedger.transition(ledger, action.id, :needs_input)
    assert waiting.blocker_classification == "goal.stalled"

    assert {:ok, duplicate, :existing} = ActionLedger.plan(ledger, stalled)
    assert duplicate.id == action.id

    parent = self()

    assert {:error, {:action_not_dispatchable, action_id, :needs_input}} =
             CoordinationAdapter.dispatch(ledger, stalled, fn ->
               send(parent, :duplicate_decision_prompt)
               {:ok, :presented, %{}}
             end)

    assert action_id == action.id
    refute_received :duplicate_decision_prompt

    assert {:error, :resume_condition_mismatch} =
             ActionLedger.resume_goal(ledger, action.id, "decision.wrong")

    assert {:ok, resumed} =
             ActionLedger.resume_goal(
               ledger,
               action.id,
               "decision.customer_contract_selected"
             )

    assert resumed.state == :planned

    other = plan_with_checkpoint(ledger, "unrelated-lane")
    assert other.state == :planned
    assert %{pending: pending} = ActionLedger.reconcile(ledger)
    assert Enum.map(pending, & &1.id) == [action.id, other.id]
  end

  test "expired or failed approval preconditions cancel before presentation or execution", %{path: path} do
    ledger = start_ledger(path)
    parent = self()

    expired =
      intent(%{
        kind: :task_messaging,
        checkpoint: "approval-expired",
        valid_until: "2026-08-31T00:00:00Z"
      })

    assert {:error, {:approval_obsolete, :expired}} =
             CoordinationAdapter.dispatch(
               ledger,
               expired,
               fn ->
                 send(parent, :expired_approval_presented)
                 {:ok, :presented, %{}}
               end,
               now: ~U[2026-08-31 00:00:01Z]
             )

    refute_received :expired_approval_presented
    assert {:ok, expired_action, :existing} = ActionLedger.plan(ledger, expired)
    assert expired_action.state == :preflight_rejected
    assert expired_action.observed_effect["disposition"] == "approval_obsolete"

    stale = intent(%{kind: :automation, checkpoint: "approval-stale"})

    assert {:error, {:approval_obsolete, :head_changed}} =
             CoordinationAdapter.dispatch(
               ledger,
               stale,
               fn ->
                 send(parent, :stale_approval_executed)
                 {:ok, :executed, %{}}
               end,
               precondition: fn -> {:error, :head_changed} end
             )

    refute_received :stale_approval_executed
  end

  test "stored envelope identity changes fail startup closed", %{path: path} do
    ledger = start_ledger(path)
    assert {:ok, _action, :new} = ActionLedger.plan(ledger, intent())
    GenServer.stop(ledger)

    tampered =
      path
      |> File.read!()
      |> String.replace("revision-1", "revision-x", global: false)

    File.write!(path, tampered)
    assert {:error, {:ledger_corrupt, _child}} = start_ledger_result(path)
  end

  test "transition telemetry carries bounded correlation and policy but no content", %{path: path} do
    ledger = start_ledger(path)
    handler_id = "action-ledger-test-#{System.unique_integer([:positive, :monotonic])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:symphony, :action_ledger, :transition],
        fn event, measurements, metadata, _config ->
          send(parent, {:transition_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, action, :new} = ActionLedger.plan(ledger, intent())

    assert_receive {:transition_telemetry, [:symphony, :action_ledger, :transition], %{count: 1}, metadata}

    assert metadata.action_id == action.id
    assert metadata.policy_fingerprint == action.policy_fingerprint
    assert metadata.issue_id == "issue-1"
    refute Map.has_key?(metadata, :purpose)
    refute Map.has_key?(metadata, :prompt)
    refute inspect(metadata) =~ "dispatch-current-issue"
  end

  test "default server API and disabled mutation behavior", %{path: path} do
    start_supervised!({ActionLedger, name: ActionLedger, path: path})
    assert {:ok, action, :new} = ActionLedger.plan(intent())
    assert {:ok, observed} = ActionLedger.observe_effect(action.id, %{"disposition" => "observed"})
    assert observed.observed_effect["disposition"] == "observed"

    assert {:ok, stalled, :new} =
             ActionLedger.plan(
               intent(%{
                 kind: :task_messaging,
                 checkpoint: "default-stalled",
                 blocker_classification: "goal.stalled",
                 resume_condition: "decision.ready"
               })
             )

    assert {:ok, _waiting} = ActionLedger.transition(stalled.id, :needs_input)
    assert {:ok, resumed} = ActionLedger.resume_goal(stalled.id, "decision.ready")
    assert resumed.state == :planned

    disabled_path = Path.rootname(path) <> "-disabled.jsonl"
    disabled = start_ledger(disabled_path, enabled: false)
    assert {:error, :action_ledger_disabled} = ActionLedger.plan(disabled, intent())
    refute ActionLedger.enabled?(disabled)
  end

  test "invalid envelopes, transitions, and lookups fail closed", %{path: path} do
    ledger = start_ledger(path)
    assert :error = ActionLedger.get(ledger, "act_missing")
    assert {:error, :action_not_found} = ActionLedger.transition(ledger, "act_missing", :dispatched)
    assert {:error, :action_not_found} = ActionLedger.observe_effect(ledger, "act_missing", %{})
    assert {:error, :action_not_found} = ActionLedger.resume_goal(ledger, "act_missing", "decision.ready")

    assert {:error, :intent_invalid} = ActionLedger.plan(ledger, :invalid)
    assert {:error, :action_kind_invalid} = ActionLedger.plan(ledger, intent(%{kind: "unknown"}))
    assert {:error, :action_kind_invalid} = ActionLedger.plan(ledger, intent(%{kind: 123}))
    assert {:error, :bounded_map_invalid} = ActionLedger.plan(ledger, intent(%{source: :invalid}))
    assert {:error, {:purpose, :invalid}} = ActionLedger.plan(ledger, intent(%{purpose: 123}))

    assert {:error, {:policy_fingerprint, :invalid}} =
             ActionLedger.plan(ledger, intent(%{policy_fingerprint: "not-a-hash"}))

    assert {:error, {:policy_fingerprint, :invalid}} =
             ActionLedger.plan(ledger, intent(%{policy_fingerprint: nil}))

    assert {:error, {:stalled_goal_fields, :invalid}} =
             ActionLedger.plan(ledger, intent(%{blocker_classification: "goal.stalled"}))

    assert {:error, {:resume_condition, :invalid}} =
             ActionLedger.plan(
               ledger,
               intent(%{
                 blocker_classification: "goal.stalled",
                 resume_condition: "not valid spaces"
               })
             )

    assert {:error, {:valid_until, :invalid}} =
             ActionLedger.plan(ledger, intent(%{valid_until: "not-a-time"}))

    assert {:error, {:valid_until, :invalid}} =
             ActionLedger.plan(ledger, intent(%{valid_until: 123}))

    assert {:ok, action, :new} =
             ActionLedger.plan(ledger, intent(%{source: %{issue_id: "issue-nil", session_id: nil}}))

    assert action.source == %{"issue_id" => "issue-nil"}
    assert {:error, :action_state_invalid} = ActionLedger.transition(ledger, action.id, "unknown")
    assert {:error, :action_state_invalid} = ActionLedger.transition(ledger, action.id, 123)
    assert {:error, :bounded_map_invalid} = ActionLedger.observe_effect(ledger, action.id, :invalid)

    assert {:error, :action_not_stalled_goal} =
             ActionLedger.resume_goal(ledger, action.id, "decision.ready")
  end

  test "empty, unreadable, wrong-schema, and invalid replay state all fail deterministically", %{
    root: root
  } do
    empty = Path.join(root, "empty.jsonl")
    File.write!(empty, "")
    empty_ledger = start_ledger(empty)
    assert ActionLedger.reconcile(empty_ledger).pending == []
    GenServer.stop(empty_ledger)

    directory_path = Path.join(root, "directory-ledger")
    File.mkdir_p!(directory_path)
    assert {:error, {{:ledger_read_failed, :eisdir}, _child}} = start_ledger_result(directory_path)

    wrong_schema = Path.join(root, "wrong-schema.jsonl")
    File.write!(wrong_schema, Jason.encode!(%{"schema" => "wrong"}) <> "\n")
    assert {:error, {:ledger_corrupt, _child}} = start_ledger_result(wrong_schema)

    invalid_timestamp = Path.join(root, "invalid-timestamp.jsonl")
    ledger = start_ledger(invalid_timestamp)
    assert {:ok, _action, :new} = ActionLedger.plan(ledger, intent())
    GenServer.stop(ledger)
    [encoded] = invalid_timestamp |> File.read!() |> String.split("\n", trim: true)
    raw = encoded |> Jason.decode!() |> Map.put("inserted_at", "not-a-time")
    File.write!(invalid_timestamp, Jason.encode!(raw) <> "\n")
    assert {:error, {:ledger_corrupt, _child}} = start_ledger_result(invalid_timestamp)

    invalid_replay = Path.join(root, "invalid-replay.jsonl")
    replay_ledger = start_ledger(invalid_replay)
    assert {:ok, replay_action, :new} = ActionLedger.plan(replay_ledger, intent())

    assert {:ok, _terminal} =
             ActionLedger.transition(replay_ledger, replay_action.id, :preflight_rejected)

    GenServer.stop(replay_ledger)
    [planned_line, _terminal_line] = invalid_replay |> File.read!() |> String.split("\n", trim: true)
    File.write!(invalid_replay, File.read!(invalid_replay) <> planned_line <> "\n")
    assert {:error, {:ledger_corrupt, _child}} = start_ledger_result(invalid_replay)
  end

  test "adapter error paths never leak an unrecorded effect", %{root: root} do
    nil_ledger_intent = intent()

    assert {:error, :known_failure} =
             CoordinationAdapter.dispatch(nil, nil_ledger_intent, fn ->
               {:error, :known_failure, :retryable_failure}
             end)

    assert {:error, {:coordination_effect_invalid, :bad_result}} =
             CoordinationAdapter.dispatch(nil, nil_ledger_intent, fn -> :bad_result end)

    ledger_path = Path.join([root, "adapter-errors", "ledger.jsonl"])
    ledger = start_ledger(ledger_path)

    assert {:error, :intent_invalid} =
             CoordinationAdapter.dispatch(ledger, :invalid, fn -> {:ok, :never, %{}} end)

    assert {:error, {:approval_obsolete, {:invalid_precondition_result, :unknown}}} =
             CoordinationAdapter.dispatch(
               ledger,
               intent(%{checkpoint: "invalid-precondition"}),
               fn -> {:ok, :never, %{}} end,
               precondition: fn -> :unknown end
             )

    assert {:error, {:coordination_effect_invalid, :bad_result}} =
             CoordinationAdapter.dispatch(
               ledger,
               intent(%{checkpoint: "invalid-effect"}),
               fn -> :bad_result end
             )

    assert {:ok, :spawned, observed} =
             CoordinationAdapter.dispatch(
               ledger,
               intent(%{checkpoint: "nonterminal-success"}),
               fn -> {:ok, :spawned, %{"disposition" => "spawned"}} end,
               terminal_on_success: false
             )

    assert observed.state == :dispatched

    assert {:already_satisfied, satisfied} =
             CoordinationAdapter.dispatch(
               ledger,
               intent(%{checkpoint: "already-satisfied"}),
               fn -> {:already_satisfied, %{"disposition" => "exists"}} end
             )

    assert satisfied.state == :already_satisfied
  end

  defp start_ledger(path, opts \\ []) do
    case start_ledger_result(path, opts) do
      {:ok, pid} -> pid
      {:error, reason} -> flunk("ledger failed to start: #{inspect(reason)}")
    end
  end

  defp start_ledger_result(path, opts \\ []) do
    name = String.to_atom("ledger_#{System.unique_integer([:positive, :monotonic])}")

    {ActionLedger, Keyword.merge([name: name, path: path], opts)}
    |> Supervisor.child_spec(id: name, restart: :temporary)
    |> start_supervised()
  end

  defp intent(overrides \\ %{}) do
    defaults = %{
      kind: :task_creation,
      source: %{goal_id: "goal-1", task_id: "task-1", issue_id: "issue-1", revision: "revision-1"},
      target: %{type: "codex_task", worker_host: "local"},
      purpose: "dispatch-current-issue",
      checkpoint: "revision-1",
      expected_postcondition: "worker.started",
      policy_fingerprint: ActionLedger.policy_fingerprint("test-policy-v1")
    }

    Map.merge(defaults, overrides)
  end

  defp plan_with_checkpoint(ledger, checkpoint) do
    assert {:ok, action, :new} = ActionLedger.plan(ledger, intent(%{checkpoint: checkpoint}))
    action
  end

  defp reach_state(_ledger, action, :planned), do: action

  defp reach_state(ledger, action, :dispatched) do
    {:ok, action} = ActionLedger.transition(ledger, action.id, :dispatched)
    action
  end

  defp reach_state(ledger, action, :uncertain) do
    action = reach_state(ledger, action, :dispatched)
    {:ok, action} = ActionLedger.transition(ledger, action.id, :uncertain)
    action
  end

  defp reach_state(ledger, action, :retryable_failure) do
    action = reach_state(ledger, action, :dispatched)
    {:ok, action} = ActionLedger.transition(ledger, action.id, :retryable_failure)
    action
  end

  defp reach_state(ledger, action, :quarantined) do
    {:ok, action} = ActionLedger.transition(ledger, action.id, :quarantined)
    action
  end

  defp reach_state(ledger, action, :needs_input) do
    {:ok, action} = ActionLedger.transition(ledger, action.id, :needs_input)
    action
  end
end
