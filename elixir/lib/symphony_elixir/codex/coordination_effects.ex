defmodule SymphonyElixir.Codex.CoordinationEffects do
  @moduledoc """
  Ledger-backed Codex coordination effects.

  The native Codex App Server supports persisted-thread reads and forks. The
  desktop-only Codex App Tools MCP families require a live desktop host pipe
  plus executor metadata; Symphony does not own that host binding. They are
  therefore persisted as explicit preflight rejections instead of being
  simulated or retried blindly.
  """

  alias SymphonyElixir.{ActionLedger, CoordinationAdapter}
  alias SymphonyElixir.ActionLedger.Action
  alias SymphonyElixir.Codex.AppServer

  @type operation :: :task_messaging | :automation | :fork | :handoff

  @unsupported_operations [:task_messaging, :automation, :handoff]

  @doc "Returns the provider capability state without probing or mutating the desktop host."
  @spec capability(operation()) :: :supported | :unsupported
  def capability(:fork), do: :supported
  def capability(operation) when operation in @unsupported_operations, do: :unsupported

  @doc "Records a known-unsupported desktop-only coordination operation fail closed."
  @spec reject_unsupported(GenServer.server(), ActionLedger.intent(), operation()) ::
          CoordinationAdapter.dispatch_result(term())
  def reject_unsupported(ledger, intent, operation) when operation in @unsupported_operations do
    CoordinationAdapter.dispatch(
      ledger,
      intent,
      &unsupported_effect/0,
      precondition: fn -> unsupported_preflight(operation) end
    )
  end

  @doc "Forks a stored Codex thread with intent-before-effect and a provider-backed postcondition."
  @spec dispatch_fork(GenServer.server(), ActionLedger.intent(), Path.t(), keyword()) ::
          CoordinationAdapter.dispatch_result(map())
  def dispatch_fork(ledger, intent, workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    case validate_fork_intent(intent) do
      :ok ->
        CoordinationAdapter.dispatch(
          ledger,
          intent,
          fn -> fork_effect(workspace, target_id(intent), opts) end,
          inspect_recovered: &inspect_recovered_fork(&1, workspace),
          precondition: fn -> :ok end
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Inspects an uncertain fork without creating, resuming, or modifying any provider thread."
  @spec inspect_recovered_fork(Action.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def inspect_recovered_fork(%Action{kind: :fork} = action, workspace) when is_binary(workspace) do
    source_thread_id = get_in(action.target, ["id"])
    fork_thread_id = get_in(action.observed_effect, ["fork_thread_id"])

    cond do
      not is_binary(source_thread_id) ->
        {:ok, non_authoritative_evidence("source_thread_missing")}

      not is_binary(fork_thread_id) ->
        # App Server has no stable idempotency key or exact-fork query. A
        # crash after dispatch but before a returned child id must not cause a
        # search-and-guess or a duplicate fork.
        {:ok, non_authoritative_evidence("fork_identity_unrecorded")}

      true ->
        inspect_recorded_fork(workspace, source_thread_id, fork_thread_id)
    end
  end

  def inspect_recovered_fork(%Action{}, _workspace), do: {:error, :fork_action_required}

  defp fork_effect(workspace, source_thread_id, opts) do
    with {:ok, result} <-
           AppServer.with_control_connection(workspace, &read_and_fork(&1, source_thread_id, opts)),
         {:ok, source_thread, fork_thread} <- result,
         {:ok, effect} <- fork_effect_evidence(source_thread, fork_thread, source_thread_id) do
      {:ok, fork_thread, effect}
    else
      {:error, reason} -> {:error, reason, :retryable_failure}
    end
  end

  defp read_and_fork(connection, source_thread_id, opts) do
    with {:ok, source_thread} <- AppServer.read_stored_thread(connection, source_thread_id),
         {:ok, fork_thread} <- AppServer.fork_stored_thread(connection, source_thread_id, opts) do
      {:ok, source_thread, fork_thread}
    end
  end

  defp inspect_recorded_fork(workspace, source_thread_id, fork_thread_id) do
    case AppServer.with_control_connection(workspace, fn connection ->
           AppServer.read_stored_thread(connection, fork_thread_id)
         end) do
      {:ok, {:ok, fork_thread}} ->
        case fork_effect_evidence(%{"id" => source_thread_id}, fork_thread, source_thread_id) do
          {:ok, evidence} -> {:ok, Map.merge(evidence, %{"provider" => "codex", "authoritative" => true, "exists" => true})}
          {:error, _reason} -> {:ok, non_authoritative_evidence("fork_postcondition_mismatch")}
        end

      {:ok, {:error, _reason}} ->
        {:ok, non_authoritative_evidence("fork_read_failed")}

      {:error, _reason} ->
        {:ok, non_authoritative_evidence("provider_unavailable")}
    end
  end

  defp fork_effect_evidence(source_thread, fork_thread, source_thread_id) do
    with ^source_thread_id <- Map.get(source_thread, "id"),
         ^source_thread_id <- Map.get(fork_thread, "forkedFromId"),
         fork_thread_id when is_binary(fork_thread_id) <- Map.get(fork_thread, "id"),
         false <- fork_thread_id == source_thread_id do
      effect =
        %{
          "thread_id" => source_thread_id,
          "fork_thread_id" => fork_thread_id,
          "session_id" => Map.get(fork_thread, "sessionId"),
          "disposition" => "thread_forked"
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {:ok, effect}
    else
      _ -> {:error, :fork_postcondition_mismatch}
    end
  end

  defp non_authoritative_evidence(disposition) do
    %{"provider" => "codex", "authoritative" => false, "exists" => false, "disposition" => disposition}
  end

  # The precondition always runs before this callback. Keeping the callback
  # separate makes an accidental execution fail closed as well.
  defp unsupported_effect, do: {:error, :provider_capability_unsupported, :preflight_rejected}

  defp unsupported_preflight(operation) do
    with {:error, :provider_capability_unsupported, :preflight_rejected} <- unsupported_effect() do
      {:error, {:provider_capability_unsupported, operation}}
    end
  end

  defp validate_fork_intent(intent) when is_map(intent) do
    case {value(intent, :kind), value(intent, :expected_postcondition), target_id(intent)} do
      {kind, "codex.thread_forked", thread_id} when kind in [:fork, "fork"] and is_binary(thread_id) -> :ok
      _ -> {:error, :fork_intent_invalid}
    end
  end

  defp validate_fork_intent(_intent), do: {:error, :fork_intent_invalid}

  defp target_id(intent) when is_map(intent) do
    intent
    |> value(:target)
    |> case do
      target when is_map(target) -> value(target, :id)
      _ -> nil
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
