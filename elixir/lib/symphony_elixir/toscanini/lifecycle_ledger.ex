defmodule SymphonyElixir.Toscanini.LifecycleLedger do
  @moduledoc """
  Ledger boundary for Toscanini commands and factual events.

  Envelopes are validated by `EventContract` before they cross the durable
  coordination boundary. Commands use the normal coordination adapter (and
  therefore are dispatched at most once for an idempotent intent); events are
  recorded as terminal ledger observations. The ledger remains the authority
  for delivery, while EventContract remains the authority for lifecycle
  transitions.
  """

  alias SymphonyElixir.{ActionLedger, CoordinationAdapter}
  alias SymphonyElixir.ActionLedger.Action
  alias SymphonyElixir.Toscanini.EventContract

  @type result ::
          {:ok, term(), Action.t()}
          | {:already_satisfied, Action.t()}
          | {:error, term()}

  @spec command(GenServer.server(), term(), (-> term()), keyword()) :: result()
  def command(ledger, envelope, effect_fun, opts \\ []) do
    with {:ok, envelope} <- EventContract.new(envelope),
         true <- EventContract.command?(envelope) do
      intent = intent(envelope, :command)
      CoordinationAdapter.dispatch(ledger, intent, effect_fun, opts)
    else
      false -> {:error, :command_required}
      error -> error
    end
  end

  @doc "Alias with an explicit delivery-oriented name for command callers."
  @spec dispatch_command(GenServer.server(), term(), (-> term()), keyword()) :: result()
  def dispatch_command(ledger, envelope, effect_fun, opts \\ []),
    do: command(ledger, envelope, effect_fun, opts)

  @spec event(GenServer.server(), term()) :: result()
  def event(ledger, envelope) do
    case event(ledger, envelope, EventContract.initial_state()) do
      {:ok, _state, action} -> {:ok, envelope, action}
      other -> other
    end
  end

  @doc "Validate and persist an event against the caller's lifecycle state."
  @spec event(GenServer.server(), term(), EventContract.state()) ::
          {:ok, EventContract.state(), Action.t()} | {:already_satisfied, Action.t()} | {:error, term()}
  def event(ledger, envelope, state) do
    with {:ok, envelope} <- EventContract.new(envelope),
         true <- EventContract.event?(envelope),
         {:ok, next_state} <- EventContract.transition(state, envelope),
         intent = intent(envelope, :event),
         {:ok, action, disposition} <- ActionLedger.plan(ledger, intent) do
      case persist_event(ledger, action, disposition, envelope) do
        {:ok, _envelope, recorded} -> {:ok, next_state, recorded}
        {:already_satisfied, recorded} -> {:already_satisfied, recorded}
        error -> error
      end
    else
      false -> {:error, :event_required}
      error -> error
    end
  end

  @doc "Alias with an explicit persistence-oriented name for event callers."
  @spec record_event(GenServer.server(), term()) :: result()
  def record_event(ledger, envelope), do: event(ledger, envelope)

  @spec replay([term()], EventContract.state()) :: EventContract.result(EventContract.state())
  def replay(envelopes, state \\ EventContract.initial_state()) when is_list(envelopes) do
    EventContract.replay(envelopes, state)
  end

  @spec diagnostics(GenServer.server()) :: map()
  def diagnostics(ledger) do
    reconciliation = ActionLedger.reconcile(ledger)
    pending = reconciliation.pending
    retryable = reconciliation.retryable
    quarantined = reconciliation.quarantined
    needs_input = reconciliation.needs_input

    %{
      pending: length(pending),
      retryable: length(retryable),
      quarantined: length(quarantined),
      needs_input: length(needs_input),
      total_unresolved: length(pending) + length(retryable) + length(quarantined) + length(needs_input),
      actions: %{pending: pending, retryable: retryable, quarantined: quarantined, needs_input: needs_input}
    }
  end

  defp persist_event(_ledger, %Action{state: state} = action, _disposition, _envelope)
       when state in [:succeeded, :already_satisfied],
       do: {:already_satisfied, action}

  defp persist_event(ledger, action, _disposition, envelope) do
    effect = %{
      "message_id" => envelope.id,
      "correlation_id" => envelope.correlation_id,
      "causation_id" => envelope.causation_id || "none",
      "lifecycle_state" => envelope.data.lifecycle.state,
      "sequence" => Integer.to_string(envelope.data.delivery.sequence),
      "disposition" => "event_recorded"
    }

    with {:ok, _dispatched} <- ActionLedger.transition(ledger, action.id, :dispatched),
         {:ok, recorded} <- ActionLedger.transition(ledger, action.id, :succeeded, effect) do
      {:ok, envelope, recorded}
    end
  end

  defp intent(envelope, kind) do
    identity = envelope.data.identity

    source = %{
      "programme" => identity.programme,
      "repository" => identity.repo,
      "issue_id" => Integer.to_string(identity.issue),
      "role" => identity.role,
      "task" => identity.task,
      "attempt" => Integer.to_string(identity.attempt),
      "fence" => Integer.to_string(identity.fence),
      "exact_revision" => identity.exact_revision,
      "idempotency" => envelope.data.delivery.idempotency_key,
      "correlation_id" => envelope.correlation_id
    }

    %{
      kind: :task_messaging,
      source: source,
      target: %{"type" => Atom.to_string(kind), "id" => envelope.data.recipient.id},
      purpose: Atom.to_string(kind) <> ":" <> envelope.type,
      checkpoint: identity.exact_revision,
      expected_postcondition: if(kind == :command, do: "command_delivered", else: "event_recorded"),
      policy_fingerprint: :crypto.hash(:sha256, "toscanini.lifecycle.v1") |> Base.encode16(case: :lower)
    }
  end
end
