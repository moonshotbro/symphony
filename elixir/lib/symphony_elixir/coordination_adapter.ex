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
  def dispatch(nil, _intent, effect_fun, _opts) when is_function(effect_fun, 0) do
    case effect_fun.() do
      {:ok, result, _effect} -> {:ok, result, nil}
      {:error, reason, _disposition} -> {:error, reason}
      other -> {:error, {:coordination_effect_invalid, other}}
    end
  end

  def dispatch(ledger, intent, effect_fun, opts) when is_function(effect_fun, 0) do
    case ActionLedger.plan(ledger, intent) do
      {:ok, %Action{state: state} = action, :existing}
      when state in [:succeeded, :already_satisfied] ->
        {:already_satisfied, action}

      {:ok, action, disposition} ->
        with {:ok, action} <- prepare(action, disposition, ledger),
             :ok <- preflight(action, opts),
             {:ok, _dispatched} <- ActionLedger.transition(ledger, action.id, :dispatched) do
          execute_effect(ledger, action, effect_fun, opts)
        else
          {:error, {:approval_obsolete, reason}} ->
            reject_obsolete(ledger, action, reason)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare(%Action{state: :planned} = action, _disposition, _ledger), do: {:ok, action}

  defp prepare(%Action{state: :retryable_failure} = action, _disposition, ledger) do
    ActionLedger.transition(ledger, action.id, :planned)
  end

  defp prepare(%Action{state: state} = action, :existing, _ledger)
       when state in [:dispatched, :uncertain] do
    {:error, {:uncertain_action, action.id}}
  end

  defp prepare(%Action{} = action, :existing, _ledger) do
    {:error, {:action_not_dispatchable, action.id, action.state}}
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

  defp execute_effect(ledger, action, effect_fun, opts) do
    case effect_fun.() do
      {:ok, result, effect} ->
        record_success(ledger, action, result, effect, opts)

      {:already_satisfied, effect} ->
        record_already_satisfied(ledger, action, effect)

      {:error, reason, disposition}
      when disposition in [:preflight_rejected, :retryable_failure, :quarantined, :needs_input, :terminal_failure] ->
        record_failure(ledger, action, reason, disposition)

      other ->
        {:error, {:coordination_effect_invalid, other}}
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
