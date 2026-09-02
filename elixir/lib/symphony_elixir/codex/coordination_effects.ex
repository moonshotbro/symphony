defmodule SymphonyElixir.Codex.CoordinationEffects do
  @moduledoc """
  Typed, ledger-backed boundary for native Codex coordination effects.

  Only stored-thread fork is currently provider-supported. Task messages,
  automations, and handoffs need a desktop-host attachment that Symphony does
  not own, so they are durably rejected before an effect can run.
  """

  alias SymphonyElixir.{ActionLedger, CoordinationAdapter}
  alias SymphonyElixir.ActionLedger.Action

  @type operation :: :fork | :task_messaging | :automation | :handoff
  @type provider :: %{required(:fork) => (String.t() -> term()), required(:inspect_fork) => (String.t() -> term())}
  @unsupported [:task_messaging, :automation, :handoff]

  @spec dispatch(GenServer.server() | nil, ActionLedger.intent(), operation(), provider()) ::
          CoordinationAdapter.dispatch_result(map())
  def dispatch(ledger, intent, operation, _provider) when operation in @unsupported,
    do: reject_unsupported(ledger, intent, operation)

  def dispatch(nil, _intent, :fork, _provider), do: {:error, :action_ledger_required}

  def dispatch(ledger, intent, :fork, provider) when is_map(provider) do
    with :ok <- validate_fork_intent(intent),
         {:ok, fork} <- callback(provider, :fork),
         {:ok, inspect_fork} <- callback(provider, :inspect_fork) do
      CoordinationAdapter.dispatch(
        ledger,
        intent,
        fn -> execute_fork(fork, intent) end,
        inspect_recovered: &inspect_recovered(&1, inspect_fork)
      )
    end
  end

  def dispatch(_ledger, _intent, _operation, _provider), do: {:error, :coordination_operation_invalid}

  @spec capability(operation()) :: :supported | :unsupported
  def capability(:fork), do: :supported
  def capability(operation) when operation in @unsupported, do: :unsupported

  @spec reject_unsupported(GenServer.server() | nil, ActionLedger.intent(), operation()) ::
          CoordinationAdapter.dispatch_result(term())
  def reject_unsupported(nil, _intent, _operation), do: {:error, :action_ledger_required}

  def reject_unsupported(ledger, intent, operation) when operation in @unsupported do
    CoordinationAdapter.dispatch(
      ledger,
      intent,
      &DateTime.utc_now/0,
      precondition: fn -> {:error, {:provider_capability_unsupported, operation}} end
    )
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp execute_fork(fork, intent) do
    source_id = target_id(intent)

    case fork.(source_id) do
      {:ok, %{id: child_id, forked_from_id: ^source_id, correlation_id: correlation_id} = child}
      when is_binary(child_id) and child_id != source_id and is_binary(correlation_id) and correlation_id != "" ->
        {:ok, child, effect(intent, source_id, child_id, correlation_id)}

      {:duplicate, %{id: child_id, forked_from_id: ^source_id, correlation_id: correlation_id}}
      when is_binary(child_id) and is_binary(correlation_id) and correlation_id != "" ->
        {:already_satisfied, effect(intent, source_id, child_id, correlation_id)}

      {:error, :unsupported} ->
        {:error, :provider_capability_unsupported, :terminal_failure}

      {:error, :permission} ->
        {:error, :provider_permission_denied, :terminal_failure}

      {:error, :stale_target} ->
        {:error, :provider_stale_target, :retryable_failure}

      {:error, reason} when reason in [:capacity, :conflict] ->
        {:error, {:provider_conflict, reason}, :retryable_failure}

      {:error, reason} when reason in [:zero_response, :timeout, :eof, :connection_closed, :provider_exit] ->
        {:error, reason, :uncertain}

      {:error, reason} ->
        {:error, reason, :uncertain}

      _ ->
        {:error, :provider_fork_response_invalid, :uncertain}
    end
  end

  defp inspect_recovered(%Action{kind: :fork, observed_effect: effect} = action, inspect_fork) do
    case Map.get(effect, "fork_thread_id") do
      child_id when is_binary(child_id) ->
        inspect_child(inspect_fork, child_id, action)

      _ ->
        {:ok, %{provider: "codex", authoritative: false, exists: false, disposition: "fork_identity_unrecorded"}}
    end
  end

  defp inspect_child(inspect_fork, child_id, action) do
    expected_source = Map.get(action.target, "id")

    case inspect_fork.(child_id) do
      {:ok, %{id: ^child_id, forked_from_id: ^expected_source} = child} ->
        if exact_recovered_child?(child, action) do
          {:ok,
           %{
             provider: "codex",
             authoritative: true,
             exists: true,
             session_correlation_id: child_value(child, "sessionId"),
             workspace_key: Map.get(action.observed_effect, "workspace_key"),
             disposition: "thread_forked"
           }}
        else
          {:ok, %{provider: "codex", authoritative: false, exists: false, disposition: "fork_authority_mismatch"}}
        end

      {:ok, %{id: ^child_id, forked_from_id: _source}} ->
        {:ok, %{provider: "codex", authoritative: false, exists: false, disposition: "fork_source_mismatch"}}

      {:error, reason} when reason in [:not_found, :thread_not_found] ->
        {:ok, %{provider: "codex", authoritative: true, exists: false, disposition: "thread_fork_absent"}}

      _ ->
        {:ok, %{provider: "codex", authoritative: false, exists: false, disposition: "fork_inspection_ambiguous"}}
    end
  end

  defp exact_recovered_child?(child, action) do
    source = action.source
    effect = action.observed_effect
    git_info = child_value(child, "gitInfo")

    child_value(child, "cwd") == Map.get(source, "workspace_path") and
      child_value(child, "projectId") == Map.get(source, "native_project_id") and
      child_value(child, "ephemeral") == false and
      valid_string?(child_value(child, "sessionId")) and
      child_value(child, "sessionId") == Map.get(effect, "session_correlation_id") and
      child_value(child, "worker_host") == Map.get(source, "worker_host") and
      is_map(git_info) and child_value(git_info, "sha") == Map.get(source, "revision") and
      repository_name(child_value(git_info, "originUrl")) == Map.get(source, "repository")
  end

  defp child_value(map, key), do: Map.get(map, key, Map.get(map, child_key_atom(key)))
  defp child_key_atom("cwd"), do: :cwd
  defp child_key_atom("projectId"), do: :project_id
  defp child_key_atom("ephemeral"), do: :ephemeral
  defp child_key_atom("sessionId"), do: :session_id
  defp child_key_atom("worker_host"), do: :worker_host
  defp child_key_atom("gitInfo"), do: :git_info
  defp child_key_atom("sha"), do: :sha
  defp child_key_atom("originUrl"), do: :origin_url
  defp valid_string?(value), do: is_binary(value) and value != ""

  defp repository_name(remote) when is_binary(remote) do
    remote
    |> String.replace(~r/^git@[^:]+:/, "")
    |> String.replace(~r|^https?://[^/]+/|, "")
    |> String.replace_suffix(".git", "")
  end

  defp repository_name(_), do: nil

  defp effect(intent, source_id, child_id, correlation_id) do
    source = value(intent, :source)

    %{
      "thread_id" => source_id,
      "fork_thread_id" => child_id,
      "session_correlation_id" => correlation_id,
      "worker_host" => value(source, :worker_host),
      "workspace_key" => value(source, :workspace_path),
      "revision" => value(source, :revision),
      "disposition" => "thread_forked"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp validate_fork_intent(intent) when is_map(intent) do
    source = value(intent, :source)

    if value(intent, :kind) in [:fork, "fork"] and value(intent, :expected_postcondition) == "codex.thread_forked" and
         is_map(source) and Enum.all?([:task_id, :correlation_id, :fence, :attempt, :issue_id, :repository, :revision, :native_project_id], &valid_identity?(value(source, &1))) and
         valid_identity?(target_id(intent)), do: :ok, else: {:error, :fork_intent_invalid}
  end

  defp validate_fork_intent(_), do: {:error, :fork_intent_invalid}
  defp valid_identity?(value), do: is_binary(value) and value != "" and byte_size(value) <= 256

  defp callback(provider, key) do
    case Map.get(provider, key) do
      fun when is_function(fun, 1) -> {:ok, fun}
      _ -> {:error, {:provider_callback_missing, key}}
    end
  end

  defp target_id(intent), do: intent |> value(:target) |> then(fn target -> if is_map(target), do: value(target, :id), else: nil end)
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
