defmodule SymphonyElixir.Codex.CoordinationEffectsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ActionLedger
  alias SymphonyElixir.Codex.CoordinationEffects

  setup do
    path = Path.join(System.tmp_dir!(), "coordination-effects-#{System.unique_integer([:positive])}.jsonl")
    {:ok, ledger} = ActionLedger.start_link(name: nil, path: path)

    on_exit(fn ->
      if Process.alive?(ledger), do: GenServer.stop(ledger)
      File.rm(path)
    end)

    %{ledger: ledger, path: path}
  end

  test "records successful native fork before effect and suppresses a duplicate", %{ledger: ledger} do
    parent = self()

    provider =
      provider(fn source ->
        send(parent, {:fork, source})
        {:ok, child()}
      end)

    assert {:ok, %{id: "child-1"}, action} = CoordinationEffects.dispatch(ledger, intent(), :fork, provider)
    assert action.state == :succeeded
    assert_received {:fork, "source-1"}
    assert {:already_satisfied, duplicate} = CoordinationEffects.dispatch(ledger, intent(), :fork, provider)
    assert duplicate.id == action.id
    refute_received {:fork, "source-1"}
  end

  test "rejects unsupported desktop-only operations before the callback", %{ledger: ledger} do
    assert {:error, {:approval_obsolete, {:provider_capability_unsupported, :handoff}}} =
             CoordinationEffects.dispatch(ledger, unsupported_intent(:handoff), :handoff, %{})

    assert {:ok, action} = action_for(ledger, unsupported_intent(:handoff))
    assert action.state == :preflight_rejected
    assert action.observed_effect["disposition"] == "approval_obsolete"
  end

  test "classifies stale target, permission, capacity, and conflict without succeeding", %{ledger: ledger} do
    cases = [
      stale_target: :retryable_failure,
      permission: :terminal_failure,
      capacity: :retryable_failure,
      conflict: :retryable_failure
    ]

    for {reason, expected} <- cases do
      {:error, _} =
        CoordinationEffects.dispatch(
          ledger,
          intent("#{reason}"),
          :fork,
          provider(fn _ -> {:error, reason} end)
        )

      assert {:ok, action} = action_for(ledger, intent("#{reason}"))
      assert action.state == expected
    end
  end

  test "zero-response becomes uncertain and cannot be blindly replayed", %{ledger: ledger} do
    assert {:error, :zero_response} =
             CoordinationEffects.dispatch(
               ledger,
               intent(),
               :fork,
               provider(fn _ -> {:error, :zero_response} end)
             )

    assert {:ok, action} = action_for(ledger, intent())
    assert action.state == :uncertain

    assert {:error, {:uncertain_action_quarantined, _}} =
             CoordinationEffects.dispatch(ledger, intent(), :fork, provider(fn _ -> {:ok, child()} end))
  end

  test "ambiguous post-effect inspection remains held while exact child read settles it", %{ledger: ledger} do
    {:ok, action, :new} = ActionLedger.plan(ledger, intent())
    {:ok, _} = ActionLedger.transition(ledger, action.id, :dispatched)

    {:ok, _} =
      ActionLedger.transition(ledger, action.id, :uncertain, %{
        "thread_id" => "source-1",
        "fork_thread_id" => "child-1",
        "disposition" => "zero_response"
      })

    assert {:already_satisfied, settled} =
             CoordinationEffects.dispatch(ledger, intent(), :fork, provider(fn _ -> raise "must not fork" end))

    assert settled.state == :already_satisfied
  end

  test "restart turns dispatched action uncertain and preserves duplicate suppression", %{ledger: ledger, path: path} do
    intent = intent()
    {:ok, action, :new} = ActionLedger.plan(ledger, intent)
    {:ok, _} = ActionLedger.transition(ledger, action.id, :dispatched)
    GenServer.stop(ledger)
    {:ok, restarted} = ActionLedger.start_link(name: nil, path: path)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)

    assert {:ok, recovered} = ActionLedger.get(restarted, action.id)
    assert recovered.state == :uncertain

    assert {:error, {:uncertain_action_quarantined, _}} =
             CoordinationEffects.dispatch(restarted, intent, :fork, provider(fn _ -> {:ok, child()} end))
  end

  test "rejects missing identity and private payload keys before provider invocation", %{ledger: ledger} do
    parent = self()

    provider =
      provider(fn _ ->
        send(parent, :called)
        {:ok, child()}
      end)

    assert {:error, :fork_intent_invalid} =
             CoordinationEffects.dispatch(
               ledger,
               put_in(intent(), [:source, :attempt], nil),
               :fork,
               provider
             )

    refute_received :called

    private = put_in(intent(), [:source, :prompt], "customer content")
    assert {:error, {:field_not_allowed, "prompt"}} = CoordinationEffects.dispatch(ledger, private, :fork, provider)
    refute_received :called
  end

  test "fails closed without a ledger or required provider callbacks", %{ledger: ledger} do
    assert {:error, :action_ledger_required} = CoordinationEffects.dispatch(nil, intent(), :fork, %{})
    assert {:error, :action_ledger_required} = CoordinationEffects.reject_unsupported(nil, intent(), :handoff)
    assert {:error, {:provider_callback_missing, :fork}} = CoordinationEffects.dispatch(ledger, intent(), :fork, %{})

    assert {:error, {:provider_callback_missing, :inspect_fork}} =
             CoordinationEffects.dispatch(ledger, intent(), :fork, %{fork: fn _ -> {:ok, child()} end})

    assert {:error, :coordination_operation_invalid} = CoordinationEffects.dispatch(ledger, intent(), :unknown, %{})

    assert {:error, :fork_intent_invalid} =
             CoordinationEffects.dispatch(
               ledger,
               :invalid,
               :fork,
               provider(fn _ -> {:ok, child()} end)
             )
  end

  test "classifies provider duplicate, unsupported, invalid, and transport outcomes", %{ledger: ledger} do
    assert :supported == CoordinationEffects.capability(:fork)
    assert :unsupported == CoordinationEffects.capability(:automation)

    assert {:already_satisfied, _} =
             CoordinationEffects.dispatch(ledger, intent("duplicate"), :fork, provider(fn _ -> {:duplicate, child()} end))

    for reason <- [:unsupported, :timeout, :bad] do
      assert {:error, _} =
               CoordinationEffects.dispatch(ledger, intent("#{reason}"), :fork, provider(fn _ -> {:error, reason} end))
    end

    assert {:error, :provider_fork_response_invalid} =
             CoordinationEffects.dispatch(ledger, intent("invalid"), :fork, provider(fn _ -> :unexpected end))

    assert {:error, :provider_permission_denied} =
             CoordinationEffects.dispatch(ledger, intent("permission-direct"), :fork, provider(fn _ -> {:error, :permission} end))

    assert {:ok, %{id: "child-no-correlation"}, _} =
             CoordinationEffects.dispatch(
               ledger,
               intent("no-correlation"),
               :fork,
               provider(fn _ -> {:ok, %{id: "child-no-correlation", forked_from_id: "source-1"}} end)
             )
  end

  test "authoritative absent and source-mismatched inspections have typed outcomes", %{ledger: ledger} do
    {:ok, action, :new} = ActionLedger.plan(ledger, intent("absent"))
    {:ok, _} = ActionLedger.transition(ledger, action.id, :dispatched)
    {:ok, _} = ActionLedger.transition(ledger, action.id, :uncertain, %{"fork_thread_id" => "child-1"})

    assert {:error, {:provider_conflict, :capacity}} =
             CoordinationEffects.dispatch(
               ledger,
               intent("absent"),
               :fork,
               provider(fn _ -> {:error, :capacity} end, fn _ -> {:error, :not_found} end)
             )

    {:ok, mismatched, :new} = ActionLedger.plan(ledger, intent("mismatch"))
    {:ok, _} = ActionLedger.transition(ledger, mismatched.id, :dispatched)
    {:ok, _} = ActionLedger.transition(ledger, mismatched.id, :uncertain, %{"fork_thread_id" => "child-2"})

    assert {:error, {:uncertain_action_quarantined, _}} =
             CoordinationEffects.dispatch(
               ledger,
               intent("mismatch"),
               :fork,
               provider(fn _ -> {:ok, child()} end, fn id -> {:ok, %{id: id, forked_from_id: "wrong-source"}} end)
             )

    {:ok, ambiguous, :new} = ActionLedger.plan(ledger, intent("ambiguous"))
    {:ok, _} = ActionLedger.transition(ledger, ambiguous.id, :dispatched)
    {:ok, _} = ActionLedger.transition(ledger, ambiguous.id, :uncertain, %{"fork_thread_id" => "child-3"})

    assert {:error, {:uncertain_action_quarantined, _}} =
             CoordinationEffects.dispatch(
               ledger,
               intent("ambiguous"),
               :fork,
               provider(fn _ -> {:ok, child()} end, fn _ -> :malformed end)
             )
  end

  defp provider(fork, inspect \\ fn child_id -> {:ok, %{id: child_id, forked_from_id: "source-1"}} end),
    do: %{fork: fork, inspect_fork: inspect}

  defp child, do: %{id: "child-1", forked_from_id: "source-1", correlation_id: "corr-1"}

  defp intent(suffix \\ "one") do
    %{
      kind: :fork,
      source: %{
        task_id: "task-#{suffix}",
        correlation_id: "corr-#{suffix}",
        fence: "fence-1",
        attempt: "1",
        issue_id: "issue-39",
        repository: "moonshotbro/symphony",
        revision: "abc1234",
        native_project_id: "project-39"
      },
      target: %{type: "codex_thread", id: "source-1"},
      purpose: "coordination.fork.#{suffix}",
      checkpoint: "abc1234",
      expected_postcondition: "codex.thread_forked",
      policy_fingerprint: ActionLedger.policy_fingerprint("coordination-effects-v1")
    }
  end

  defp unsupported_intent(kind), do: %{intent() | kind: kind, expected_postcondition: "codex.#{kind}_unsupported"}

  defp action_for(ledger, intent) do
    with {:ok, action, _} <- ActionLedger.plan(ledger, intent), do: {:ok, action}
  end
end
