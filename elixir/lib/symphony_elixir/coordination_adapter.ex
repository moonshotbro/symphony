defmodule SymphonyElixir.CoordinationAdapter do
  @moduledoc """
  Structural boundary for mutating coordination effects.

  When enabled, intent is persisted before dispatch and the `dispatched`
  transition is synced before the effect function runs. A crash after that
  point leaves an uncertain action for restart reconciliation rather than a
  blind duplicate retry.
  """

  alias SymphonyElixir.ActionLedger
  alias SymphonyElixir.ActionLedger.Action

  # The legacy unledgered path exists only for older unit tests that exercise
  # the orchestrator in isolation. It is compiled out of releases and must be
  # explicitly enabled by the test support fixture; production can never use
  # it as an accidental ledger opt-out.
  @test_environment Mix.env() == :test

  @type dispatch_result(result) ::
          {:ok, result, Action.t() | nil}
          | {:already_satisfied, Action.t()}
          | {:error, term()}
          | {:error, term(), result}

  @spec dispatch(GenServer.server() | nil, ActionLedger.intent(), (-> term())) ::
          dispatch_result(term())
  def dispatch(ledger, intent, effect_fun), do: dispatch(ledger, intent, effect_fun, [])

  @spec dispatch(GenServer.server() | nil, ActionLedger.intent(), (-> term()), keyword()) ::
          dispatch_result(term())
  # A missing ledger is never an implicit opt-out for a mutating effect. A
  # legacy disabled runtime must not bypass intent persistence, idempotency,
  # preflight, and recovery by invoking the callback directly.
  def dispatch(nil, _intent, effect_fun, _opts) do
    if @test_environment and
         Application.get_env(:symphony_elixir, :test_allow_unledgered_coordination_effects, false) do
      dispatch_unledgered_for_test(effect_fun)
    else
      {:error, :action_ledger_required}
    end
  end

  def dispatch(ledger, intent, effect_fun, opts)
      when not is_nil(ledger) and is_function(effect_fun, 0) do
    case ActionLedger.plan(ledger, intent) do
      {:ok, %Action{state: state} = action, :existing}
      when state in [:succeeded, :already_satisfied] ->
        {:already_satisfied, action}

      {:ok, action, disposition} ->
        case prepare(action, disposition, ledger, opts) do
          {:already_satisfied, satisfied} ->
            {:already_satisfied, satisfied}

          {:error, reason} ->
            {:error, reason}

          {:ok, action} ->
            dispatch_prepared(ledger, action, effect_fun, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_unledgered_for_test(effect_fun) when is_function(effect_fun, 0) do
    case effect_fun.() do
      {:ok, result, _effect} -> {:ok, result, nil}
      {:error, reason, _disposition} -> {:error, reason}
      other -> {:error, {:coordination_effect_invalid, other}}
    end
  end

  defp dispatch_unledgered_for_test(_effect_fun), do: {:error, :action_ledger_required}

  defp prepare(%Action{state: :planned} = action, _disposition, _ledger, _opts), do: {:ok, action}

  defp prepare(%Action{state: :retryable_failure} = action, _disposition, ledger, _opts) do
    ActionLedger.transition(ledger, action.id, :planned)
  end

  defp prepare(%Action{state: :uncertain} = action, :existing, ledger, opts) do
    case Keyword.get(opts, :inspect_recovered) do
      inspector when is_function(inspector, 1) ->
        inspect_uncertain(ledger, action, inspector)

      _ ->
        {:error, {:uncertain_action, action.id}}
    end
  end

  defp prepare(%Action{state: :dispatched} = action, :existing, _ledger, _opts), do: {:error, {:uncertain_action, action.id}}

  defp prepare(%Action{} = action, :existing, _ledger, _opts) do
    {:error, {:action_not_dispatchable, action.id, action.state}}
  end

  defp dispatch_prepared(ledger, action, effect_fun, opts) do
    with :ok <- preflight(action, opts),
         {:ok, _dispatched} <- ActionLedger.transition(ledger, action.id, :dispatched) do
      execute_effect(ledger, action, effect_fun, opts)
    else
      {:error, {:provider_capability_unsupported, capability}} ->
        reject_unsupported(ledger, action, capability)

      {:error, {:approval_obsolete, reason}} ->
        reject_obsolete(ledger, action, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inspect_uncertain(ledger, action, inspector) do
    case inspector.(action) do
      {:ok, evidence} -> settle_uncertain(ledger, action, evidence)
      {:error, reason} -> {:error, {:inspection_failed, reason}}
      other -> {:error, {:inspection_result_invalid, other}}
    end
  end

  defp settle_uncertain(ledger, action, evidence) do
    case ActionLedger.inspect_recovered(ledger, action.id, evidence) do
      {:ok, updated, :already_satisfied} -> {:already_satisfied, updated}
      {:ok, updated, :retryable_failure} -> ActionLedger.transition(ledger, updated.id, :planned)
      {:ok, _updated, :quarantined} -> {:error, {:uncertain_action_quarantined, action.id}}
      {:error, reason} -> {:error, {:inspection_failed, reason}}
    end
  end

  defp preflight(%Action{valid_until: valid_until}, opts) do
    case not_expired(valid_until, Keyword.get(opts, :now, DateTime.utc_now())) do
      :ok -> run_precondition(Keyword.get(opts, :precondition, fn -> :ok end))
      {:error, _reason} = error -> error
    end
  end

  defp not_expired(nil, _now), do: :ok

  defp not_expired(valid_until, %DateTime{} = now) do
    {:ok, deadline, _offset} = DateTime.from_iso8601(valid_until)

    if DateTime.compare(now, deadline) == :lt,
      do: :ok,
      else: {:error, {:approval_obsolete, :expired}}
  end

  defp run_precondition(fun) when is_function(fun, 0) do
    case fun.() do
      :ok -> :ok
      {:error, {:provider_capability_unsupported, _capability}} = error -> error
      {:error, reason} -> {:error, {:approval_obsolete, reason}}
      other -> {:error, {:approval_obsolete, {:invalid_precondition_result, other}}}
    end
  end

  defp reject_obsolete(ledger, action, reason) do
    case ActionLedger.transition(ledger, action.id, :preflight_rejected, %{
           "disposition" => "approval_obsolete"
         }) do
      {:ok, _rejected} -> {:error, {:approval_obsolete, reason}}
      {:error, transition_reason} -> {:error, {:failure_record_failed, transition_reason, reason}}
    end
  end

  defp reject_unsupported(ledger, action, capability) do
    case ActionLedger.transition(ledger, action.id, :preflight_rejected, %{
           "disposition" => "provider_capability_unsupported"
         }) do
      {:ok, _rejected} ->
        {:error, {:provider_capability_unsupported, capability}}

      {:error, transition_reason} ->
        {:error, {:failure_record_failed, transition_reason, {:provider_capability_unsupported, capability}}}
    end
  end

  defp execute_effect(ledger, action, effect_fun, opts) do
    case effect_fun.() do
      {:ok, result, effect} ->
        record_success(ledger, action, result, effect, opts)

      {:already_satisfied, effect} ->
        record_already_satisfied(ledger, action, effect)

      {:error, reason, disposition}
      when disposition in [
             :preflight_rejected,
             :retryable_failure,
             :uncertain,
             :quarantined,
             :needs_input,
             :terminal_failure
           ] ->
        record_failure(ledger, action, reason, disposition)

      other ->
        case ActionLedger.transition(ledger, action.id, :uncertain, %{
               "disposition" => "invalid_effect_result"
             }) do
          {:ok, _uncertain} ->
            {:error, {:uncertain_effect, action.id, {:coordination_effect_invalid, other}}}

          {:error, reason} ->
            {:error, {:failure_record_failed, reason, {:coordination_effect_invalid, other}}}
        end
    end
  end

  defp record_success(ledger, action, result, effect, opts) do
    record_result =
      if Keyword.get(opts, :terminal_on_success, true) do
        ActionLedger.transition(ledger, action.id, :succeeded, effect)
      else
        ActionLedger.observe_effect(ledger, action.id, effect)
      end

    case record_result do
      {:ok, completed} -> {:ok, result, completed}
      {:error, reason} -> {:error, {:postcondition_record_failed, reason}, result}
    end
  end

  defp record_already_satisfied(ledger, action, effect) do
    case ActionLedger.transition(ledger, action.id, :already_satisfied, effect) do
      {:ok, completed} -> {:already_satisfied, completed}
      {:error, reason} -> {:error, {:postcondition_record_failed, reason}}
    end
  end

  defp record_failure(ledger, action, reason, disposition) do
    effect = %{"disposition" => Atom.to_string(disposition)}

    case ActionLedger.transition(ledger, action.id, disposition, effect) do
      {:ok, _failed} -> {:error, reason}
      {:error, transition_reason} -> {:error, {:failure_record_failed, transition_reason, reason}}
    end
  end
end
