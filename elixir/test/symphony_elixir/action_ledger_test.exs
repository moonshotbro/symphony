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

  test "authoritative fork inspection binds both source and child identities", %{path: path} do
    ledger = start_ledger(path)

    fork =
      intent(%{
        kind: :fork,
        target: %{type: "codex_thread", id: "thread-source"},
        expected_postcondition: "codex.thread_forked"
      })

    assert {:ok, action, :new} = ActionLedger.plan(ledger, fork)
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :dispatched)
    GenServer.stop(ledger)

    recovered = start_ledger(path)

    assert {:ok, settled, :already_satisfied} =
             ActionLedger.inspect_recovered(recovered, action.id, %{
               provider: "codex",
               authoritative: true,
               exists: true,
               thread_id: "thread-source",
               fork_thread_id: "thread-child",
               session_id: "session-root"
             })

    assert settled.observed_effect["fork_thread_id"] == "thread-child"
    assert settled.observed_effect["thread_id"] == "thread-source"

    invalid_path = Path.rootname(path) <> "-invalid-fork.jsonl"
    invalid = start_ledger(invalid_path)
    assert {:ok, invalid_action, :new} = ActionLedger.plan(invalid, fork)
    assert {:ok, _} = ActionLedger.transition(invalid, invalid_action.id, :dispatched)
    GenServer.stop(invalid)
    invalid = start_ledger(invalid_path)

    assert {:ok, quarantined, :quarantined} =
             ActionLedger.inspect_recovered(invalid, invalid_action.id, %{
               provider: "codex",
               authoritative: true,
               exists: true,
               thread_id: "wrong-source",
               fork_thread_id: "thread-child"
             })

    assert quarantined.observed_effect["disposition"] == "postcondition_evidence_mismatch"

    incomplete_path = Path.rootname(path) <> "-incomplete-fork.jsonl"
    incomplete = start_ledger(incomplete_path)
    assert {:ok, incomplete_action, :new} = ActionLedger.plan(incomplete, fork)
    assert {:ok, _} = ActionLedger.transition(incomplete, incomplete_action.id, :dispatched)
    GenServer.stop(incomplete)
    incomplete = start_ledger(incomplete_path)

    assert {:ok, incomplete, :quarantined} =
             ActionLedger.inspect_recovered(incomplete, incomplete_action.id, %{
               provider: "codex",
               authoritative: true,
               exists: true,
               thread_id: "thread-source"
             })

    assert incomplete.observed_effect["disposition"] == "postcondition_evidence_incomplete"

    provider_path = Path.rootname(path) <> "-wrong-fork-provider.jsonl"
    provider = start_ledger(provider_path)
    assert {:ok, provider_action, :new} = ActionLedger.plan(provider, fork)
    assert {:ok, _} = ActionLedger.transition(provider, provider_action.id, :dispatched)
    GenServer.stop(provider)
    provider = start_ledger(provider_path)

    assert {:ok, provider, :quarantined} =
             ActionLedger.inspect_recovered(provider, provider_action.id, %{
               provider: "desktop",
               authoritative: true,
               exists: true,
               thread_id: "thread-source",
               fork_thread_id: "thread-child"
             })

    assert provider.observed_effect["disposition"] == "provider_mismatch"
  end

  test "known unsupported provider effect is persisted as preflight rejection", %{path: path} do
    ledger = start_ledger(path)
    unsupported = intent(%{kind: :automation, expected_postcondition: "desktop.automation_updated"})

    assert {:error, {:provider_capability_unsupported, :automation}} =
             CoordinationAdapter.dispatch(
               ledger,
               unsupported,
               fn -> flunk("unsupported provider effect must not execute") end,
               precondition: fn -> {:error, {:provider_capability_unsupported, :automation}} end
             )

    assert {:ok, action, :existing} = ActionLedger.plan(ledger, unsupported)
    assert action.state == :preflight_rejected
    assert action.observed_effect["disposition"] == "provider_capability_unsupported"

    failure_path = Path.join([Path.dirname(path), "unsupported-write", "ledger.jsonl"])
    failure_ledger = start_ledger(failure_path)

    assert {:error, {:failure_record_failed, :enotdir, {:provider_capability_unsupported, :automation}}} =
             CoordinationAdapter.dispatch(
               failure_ledger,
               %{unsupported | checkpoint: "unsupported-write-failure"},
               fn -> flunk("unsupported provider effect must not execute") end,
               precondition: fn ->
                 sabotage_ledger_path(failure_path)
                 {:error, {:provider_capability_unsupported, :automation}}
               end
             )
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

    assert resumed.state == :already_satisfied

    other = plan_with_checkpoint(ledger, "unrelated-lane")
    assert other.state == :planned
    assert %{pending: pending} = ActionLedger.reconcile(ledger)
    assert Enum.map(pending, & &1.id) == [other.id]
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
    assert resumed.state == :already_satisfied

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

    nonbinary_timestamp = Path.join(root, "nonbinary-timestamp.jsonl")
    timestamp_ledger = start_ledger(nonbinary_timestamp)
    assert {:ok, _action, :new} = ActionLedger.plan(timestamp_ledger, intent())
    GenServer.stop(timestamp_ledger)
    [timestamp_line] = nonbinary_timestamp |> File.read!() |> String.split("\n", trim: true)
    timestamp_raw = timestamp_line |> Jason.decode!() |> Map.put("updated_at", 123)
    File.write!(nonbinary_timestamp, Jason.encode!(timestamp_raw) <> "\n")
    assert {:error, {:ledger_corrupt, _child}} = start_ledger_result(nonbinary_timestamp)

    invalid_replay = Path.join(root, "invalid-replay.jsonl")
    replay_ledger = start_ledger(invalid_replay)
    assert {:ok, replay_action, :new} = ActionLedger.plan(replay_ledger, intent())

    assert {:ok, _terminal} =
             ActionLedger.transition(replay_ledger, replay_action.id, :preflight_rejected)

    GenServer.stop(replay_ledger)
    [planned_line, _terminal_line] = invalid_replay |> File.read!() |> String.split("\n", trim: true)
    File.write!(invalid_replay, File.read!(invalid_replay) <> planned_line <> "\n")
    assert {:error, {:ledger_corrupt, _child}} = start_ledger_result(invalid_replay)

    assert {:error, {:ledger_path_invalid, _child}} = start_ledger_result(nil)
  end

  test "restart retains non-dispatched actions and fails closed if recovery cannot append", %{
    root: root
  } do
    planned_path = Path.join(root, "planned-restart.jsonl")
    planned_ledger = start_ledger(planned_path)
    assert {:ok, planned, :new} = ActionLedger.plan(planned_ledger, intent())
    GenServer.stop(planned_ledger)
    recovered_planned = start_ledger(planned_path)
    assert {:ok, %{state: :planned, id: planned_id}} = ActionLedger.get(recovered_planned, planned.id)
    assert planned_id == planned.id

    recovery_path = Path.join(root, "recovery-write-failure.jsonl")
    recovery_ledger = start_ledger(recovery_path)

    assert {:ok, dispatched, :new} =
             ActionLedger.plan(recovery_ledger, intent(%{checkpoint: "recovery-write-failure"}))

    assert {:ok, _} = ActionLedger.transition(recovery_ledger, dispatched.id, :dispatched)
    GenServer.stop(recovery_ledger)
    File.chmod!(recovery_path, 0o444)

    assert {:error, {{:ledger_recovery_write_failed, :eacces}, _child}} =
             start_ledger_result(recovery_path)
  end

  test "stalled-goal resume fails closed when its durable transition cannot be written", %{
    root: root
  } do
    path = Path.join([root, "resume-write-failure", "ledger.jsonl"])
    ledger = start_ledger(path)

    stalled =
      intent(%{
        checkpoint: "resume-write-failure",
        kind: :task_messaging,
        blocker_classification: "goal.stalled",
        resume_condition: "decision.ready"
      })

    assert {:ok, action, :new} = ActionLedger.plan(ledger, stalled)
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :needs_input)
    sabotage_ledger_path(path)
    assert {:error, :enotdir} = ActionLedger.resume_goal(ledger, action.id, "decision.ready")
  end

  test "uncertain action requires authoritative session and workspace inspection before retry", %{path: path} do
    ledger = start_ledger(path)
    action = plan_with_checkpoint(ledger, "inspect-before-retry")
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :uncertain)

    assert {:ok, quarantined, :quarantined} =
             ActionLedger.inspect_recovered(ledger, action.id, %{
               provider: "codex",
               authoritative: false,
               exists: true,
               session_id: "session-1",
               workspace_key: "workspace-1"
             })

    assert quarantined.state == :quarantined

    action =
      plan_action(
        ledger,
        intent(%{checkpoint: "inspect-before-retry-session", expected_postcondition: "codex.session_observed"})
      )

    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :uncertain)

    assert {:ok, settled, :already_satisfied} =
             ActionLedger.inspect_recovered(ledger, action.id, %{
               provider: "codex",
               authoritative: true,
               exists: true,
               session_id: "session-1",
               workspace_key: "workspace-1"
             })

    assert settled.state == :already_satisfied
    assert {:error, :action_not_uncertain} = ActionLedger.inspect_recovered(ledger, action.id, %{})

    incomplete =
      plan_action(
        ledger,
        intent(%{checkpoint: "inspect-incomplete", expected_postcondition: "codex.session_observed"})
      )

    assert {:ok, _} = ActionLedger.transition(ledger, incomplete.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, incomplete.id, :uncertain)

    assert {:ok, quarantined_incomplete, :quarantined} =
             ActionLedger.inspect_recovered(ledger, incomplete.id, %{
               provider: "codex",
               authoritative: true,
               exists: true,
               session_id: "session-only"
             })

    assert quarantined_incomplete.state == :quarantined

    wrong_provider =
      plan_action(
        ledger,
        intent(%{checkpoint: "inspect-wrong-provider", expected_postcondition: "codex.session_observed"})
      )

    assert {:ok, _} = ActionLedger.transition(ledger, wrong_provider.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, wrong_provider.id, :uncertain)

    assert {:ok, provider_mismatch, :quarantined} =
             ActionLedger.inspect_recovered(ledger, wrong_provider.id, %{
               provider: "linear",
               authoritative: true,
               exists: true,
               session_id: "session-1",
               workspace_key: "workspace-1"
             })

    assert provider_mismatch.observed_effect["disposition"] == "provider_mismatch"

    missing_provider = plan_with_checkpoint(ledger, "inspect-missing-provider")
    assert {:ok, _} = ActionLedger.transition(ledger, missing_provider.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, missing_provider.id, :uncertain)

    assert {:error, {:field_value_invalid, "provider"}} =
             ActionLedger.inspect_recovered(ledger, missing_provider.id, %{authoritative: true, exists: true})

    assert {:error, :inspection_invalid} = ActionLedger.inspect_recovered(ledger, missing_provider.id, :bad_evidence)

    assert {:error, :inspection_not_authoritative} =
             ActionLedger.inspect_recovered(ledger, missing_provider.id, %{
               provider: "codex",
               authoritative: "unknown",
               exists: true
             })

    assert {:error, :action_not_found} =
             ActionLedger.inspect_recovered(ledger, "act_missing", %{
               provider: "codex",
               authoritative: true,
               exists: false
             })

    assert {:error, {:field_not_allowed, "unexpected"}} =
             ActionLedger.inspect_recovered(ledger, missing_provider.id, %{
               provider: "codex",
               authoritative: true,
               exists: true,
               unexpected: "value"
             })
  end

  test "authoritative absence makes an uncertain action retryable, never an implicit dispatch", %{path: path} do
    ledger = start_ledger(path)
    action = plan_with_checkpoint(ledger, "inspect-absent")
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, action.id, :uncertain)

    assert {:ok, retryable, :retryable_failure} =
             ActionLedger.inspect_recovered(ledger, action.id, %{
               provider: "codex",
               authoritative: true,
               exists: false
             })

    assert retryable.state == :retryable_failure
    assert {:ok, planned} = ActionLedger.transition(ledger, action.id, :planned)
    assert planned.state == :planned

    existing = plan_with_checkpoint(ledger, "inspect-generic-present")
    assert {:ok, _} = ActionLedger.transition(ledger, existing.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, existing.id, :uncertain)

    assert {:ok, satisfied, :already_satisfied} =
             ActionLedger.inspect_recovered(ledger, existing.id, %{
               provider: "linear",
               authoritative: true,
               exists: true,
               disposition: "issue_present"
             })

    assert satisfied.state == :already_satisfied
  end

  test "read-only path inspection reports corruption without repairing it", %{root: root, path: path} do
    assert {:ok, report} = ActionLedger.inspect_storage(path)
    assert report.schema == "symphony.action-ledger.v1"

    corrupt = Path.join(root, "read-only-corrupt.jsonl")
    File.write!(corrupt, "not-json\n")
    assert {:error, :ledger_corrupt} = ActionLedger.inspect_storage(corrupt)
    assert File.read!(corrupt) == "not-json\n"
  end

  test "identity-bearing values reject payload-like content", %{path: path} do
    ledger = start_ledger(path)

    assert {:error, {:field_value_invalid, "issue_id"}} =
             ActionLedger.plan(ledger, intent(%{source: %{issue_id: "Bearer secret-token"}}))

    assert {:error, {:field_value_invalid, "repository"}} =
             ActionLedger.plan(ledger, intent(%{source: %{repository: "https://example.com/repo?token=secret"}}))

    assert {:error, {:field_value_invalid, "task_id"}} =
             ActionLedger.plan(ledger, intent(%{source: %{task_id: "customer invoice contents"}}))

    assert {:error, {:field_value_invalid, "id"}} =
             ActionLedger.plan(ledger, intent(%{target: %{id: "customer document body"}}))

    assert {:error, {:field_value_invalid, "type"}} =
             ActionLedger.plan(ledger, intent(%{target: %{type: "customer document body"}}))

    assert {:error, {:checkpoint, :invalid}} =
             ActionLedger.plan(ledger, intent(%{checkpoint: "customer prompt content"}))

    assert {:ok, action, :new} = ActionLedger.plan(ledger, intent())

    assert {:error, {:field_value_invalid, "thread_id"}} =
             ActionLedger.transition(ledger, action.id, :dispatched, %{thread_id: "customer prompt content"})

    assert {:error, {:field_value_invalid, "disposition"}} =
             ActionLedger.transition(ledger, action.id, :dispatched, %{disposition: "Bearer token"})
  end

  test "default inspection API delegates to the named ledger", %{path: path} do
    {:ok, _pid} = start_supervised({ActionLedger, name: ActionLedger, path: path, enabled: true})
    assert {:ok, report} = ActionLedger.inspect_storage(path)
    assert report.action_count == 0

    action = plan_with_checkpoint(ActionLedger, "default-inspection")
    assert {:ok, _} = ActionLedger.transition(ActionLedger, action.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ActionLedger, action.id, :uncertain)

    assert {:ok, _retryable, :retryable_failure} =
             ActionLedger.inspect_recovered(action.id, %{
               provider: "codex",
               authoritative: true,
               exists: false
             })
  end

  test "adapter error paths never leak an unrecorded effect", %{root: root} do
    nil_ledger_intent = intent()

    ref = make_ref()

    assert {:error, :action_ledger_required} =
             CoordinationAdapter.dispatch(nil, nil_ledger_intent, fn ->
               send(self(), {:unexpected_effect, ref})
               {:ok, :never, %{}}
             end)

    refute_received {:unexpected_effect, ^ref}

    assert {:error, :action_ledger_required} =
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

    assert {:error, {:uncertain_effect, _action_id, {:coordination_effect_invalid, :bad_result}}} =
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

  test "a disabled ledger rejects coordination before invoking the effect", %{path: path} do
    ledger = start_ledger(path, enabled: false)
    ref = make_ref()

    assert {:error, :action_ledger_disabled} =
             CoordinationAdapter.dispatch(ledger, intent(), fn ->
               send(self(), {:unexpected_effect, ref})
               {:ok, :never, %{}}
             end)

    refute_received {:unexpected_effect, ^ref}
  end

  test "test-only unledgered compatibility is explicit and preserves result validation" do
    previous = Application.get_env(:symphony_elixir, :test_allow_unledgered_coordination_effects)
    Application.put_env(:symphony_elixir, :test_allow_unledgered_coordination_effects, true)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :test_allow_unledgered_coordination_effects)
      else
        Application.put_env(:symphony_elixir, :test_allow_unledgered_coordination_effects, previous)
      end
    end)

    assert {:ok, :result, nil} =
             CoordinationAdapter.dispatch(nil, intent(), fn -> {:ok, :result, %{}} end)

    assert {:error, :known_failure} =
             CoordinationAdapter.dispatch(nil, intent(), fn ->
               {:error, :known_failure, :retryable_failure}
             end)

    assert {:error, {:coordination_effect_invalid, :bad_result}} =
             CoordinationAdapter.dispatch(nil, intent(), fn -> :bad_result end)

    assert {:error, :action_ledger_required} =
             CoordinationAdapter.dispatch(nil, intent(), :not_a_function)
  end

  test "adapter reports every durable postcondition failure", %{root: root} do
    dispatch_path = Path.join([root, "dispatch-write", "ledger.jsonl"])
    dispatch_ledger = start_ledger(dispatch_path)

    assert {:error, :enotdir} =
             CoordinationAdapter.dispatch(
               dispatch_ledger,
               intent(%{checkpoint: "dispatch-write"}),
               fn -> {:ok, :never, %{}} end,
               precondition: fn ->
                 sabotage_ledger_path(dispatch_path)
                 :ok
               end
             )

    obsolete_path = Path.join([root, "obsolete-write", "ledger.jsonl"])
    obsolete_ledger = start_ledger(obsolete_path)
    obsolete = intent(%{checkpoint: "obsolete-write"})
    assert {:ok, _action, :new} = ActionLedger.plan(obsolete_ledger, obsolete)
    sabotage_ledger_path(obsolete_path)

    assert {:error, {:failure_record_failed, :enotdir, :expired}} =
             CoordinationAdapter.dispatch(
               obsolete_ledger,
               obsolete,
               fn -> {:ok, :never, %{}} end,
               now: ~U[2026-08-31 00:00:01Z],
               precondition: fn -> {:error, :expired} end
             )

    success_path = Path.join([root, "success-write", "ledger.jsonl"])
    success_ledger = start_ledger(success_path)

    assert {:error, {:postcondition_record_failed, :enotdir}, :effect_result} =
             CoordinationAdapter.dispatch(
               success_ledger,
               intent(%{checkpoint: "success-write"}),
               fn ->
                 sabotage_ledger_path(success_path)
                 {:ok, :effect_result, %{"disposition" => "ran"}}
               end
             )

    satisfied_path = Path.join([root, "satisfied-write", "ledger.jsonl"])
    satisfied_ledger = start_ledger(satisfied_path)

    assert {:error, {:postcondition_record_failed, :enotdir}} =
             CoordinationAdapter.dispatch(
               satisfied_ledger,
               intent(%{checkpoint: "satisfied-write"}),
               fn ->
                 sabotage_ledger_path(satisfied_path)
                 {:already_satisfied, %{"disposition" => "exists"}}
               end
             )

    failure_path = Path.join([root, "failure-write", "ledger.jsonl"])
    failure_ledger = start_ledger(failure_path)

    assert {:error, {:failure_record_failed, :enotdir, :provider_failed}} =
             CoordinationAdapter.dispatch(
               failure_ledger,
               intent(%{checkpoint: "failure-write"}),
               fn ->
                 sabotage_ledger_path(failure_path)
                 {:error, :provider_failed, :retryable_failure}
               end
             )
  end

  test "adapter inspects recovered effects before allowing a retry", %{path: path} do
    ledger = start_ledger(path)
    parent = self()
    existing_intent = intent(%{checkpoint: "adapter-inspect-existing", expected_postcondition: "codex.session_observed"})
    existing = plan_action(ledger, existing_intent)
    assert {:ok, _} = ActionLedger.transition(ledger, existing.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, existing.id, :uncertain)

    assert {:already_satisfied, _} =
             CoordinationAdapter.dispatch(
               ledger,
               existing_intent,
               fn ->
                 send(parent, :must_not_dispatch)
                 {:ok, :bad, %{}}
               end,
               inspect_recovered: fn _action ->
                 {:ok,
                  %{
                    provider: "codex",
                    authoritative: true,
                    exists: true,
                    session_id: "session-1",
                    workspace_key: "workspace-1"
                  }}
               end
             )

    refute_received :must_not_dispatch

    retry_intent = intent(%{checkpoint: "adapter-inspect-absent"})
    retry = plan_action(ledger, retry_intent)
    assert {:ok, _} = ActionLedger.transition(ledger, retry.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, retry.id, :uncertain)

    assert {:ok, :retried, _} =
             CoordinationAdapter.dispatch(
               ledger,
               retry_intent,
               fn -> {:ok, :retried, %{"disposition" => "worker_spawned"}} end,
               inspect_recovered: fn _action -> {:ok, %{provider: "codex", authoritative: true, exists: false}} end
             )

    dispatched_intent = intent(%{checkpoint: "adapter-still-dispatched"})
    dispatched = plan_action(ledger, dispatched_intent)
    assert {:ok, _} = ActionLedger.transition(ledger, dispatched.id, :dispatched)

    assert {:error, {:uncertain_action, action_id}} =
             CoordinationAdapter.dispatch(ledger, dispatched_intent, fn -> {:ok, :never, %{}} end)

    assert action_id == dispatched.id

    inspector_error_intent = intent(%{checkpoint: "adapter-inspector-error"})
    inspector_error = plan_action(ledger, inspector_error_intent)
    assert {:ok, _} = ActionLedger.transition(ledger, inspector_error.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, inspector_error.id, :uncertain)

    assert {:error, {:inspection_failed, :provider_unavailable}} =
             CoordinationAdapter.dispatch(
               ledger,
               inspector_error_intent,
               fn -> {:ok, :never, %{}} end,
               inspect_recovered: fn _action -> {:error, :provider_unavailable} end
             )

    invalid_inspector_intent = intent(%{checkpoint: "adapter-invalid-inspector"})
    invalid_inspector = plan_action(ledger, invalid_inspector_intent)
    assert {:ok, _} = ActionLedger.transition(ledger, invalid_inspector.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, invalid_inspector.id, :uncertain)

    assert {:error, {:inspection_result_invalid, :bad_inspection}} =
             CoordinationAdapter.dispatch(
               ledger,
               invalid_inspector_intent,
               fn -> {:ok, :never, %{}} end,
               inspect_recovered: fn _action -> :bad_inspection end
             )

    invalid_evidence_intent = intent(%{checkpoint: "adapter-invalid-evidence"})
    invalid_evidence = plan_action(ledger, invalid_evidence_intent)
    assert {:ok, _} = ActionLedger.transition(ledger, invalid_evidence.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, invalid_evidence.id, :uncertain)

    assert {:error, {:inspection_failed, :inspection_not_authoritative}} =
             CoordinationAdapter.dispatch(
               ledger,
               invalid_evidence_intent,
               fn -> {:ok, :never, %{}} end,
               inspect_recovered: fn _action ->
                 {:ok, %{provider: "codex", authoritative: "unknown", exists: true}}
               end
             )

    quarantined_intent = intent(%{checkpoint: "adapter-inspect-quarantine"})
    quarantined = plan_action(ledger, quarantined_intent)
    assert {:ok, _} = ActionLedger.transition(ledger, quarantined.id, :dispatched)
    assert {:ok, _} = ActionLedger.transition(ledger, quarantined.id, :uncertain)

    assert {:error, {:uncertain_action_quarantined, quarantined_id}} =
             CoordinationAdapter.dispatch(
               ledger,
               quarantined_intent,
               fn -> {:ok, :never, %{}} end,
               inspect_recovered: fn _action ->
                 {:ok, %{provider: "codex", authoritative: false, exists: true}}
               end
             )

    assert quarantined_id == quarantined.id

    invalid_effect_path = Path.join([Path.dirname(path), "invalid-effect-recording", "ledger.jsonl"])
    invalid_effect_ledger = start_ledger(invalid_effect_path)
    invalid_effect_intent = intent(%{checkpoint: "invalid-effect-recording"})
    assert {:ok, _invalid_effect_action, :new} = ActionLedger.plan(invalid_effect_ledger, invalid_effect_intent)

    assert {:error, {:failure_record_failed, :enotdir, {:coordination_effect_invalid, :bad_result}}} =
             CoordinationAdapter.dispatch(
               invalid_effect_ledger,
               invalid_effect_intent,
               fn ->
                 sabotage_ledger_path(invalid_effect_path)
                 :bad_result
               end
             )
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

  defp plan_action(ledger, action_intent) do
    assert {:ok, action, :new} = ActionLedger.plan(ledger, action_intent)
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

  defp sabotage_ledger_path(path) do
    state_dir = Path.dirname(path)
    backup_dir = state_dir <> "-backup"
    File.rename!(state_dir, backup_dir)
    File.write!(state_dir, "occupied")
  end
end
