defmodule SymphonyElixir.Codex.RecoveryInspector do
  @moduledoc """
  Reconciles a recovered task-creation action against Codex's persisted App
  Server thread record. It deliberately fails closed when the durable action
  lacks the exact thread, turn, workspace, or host assertion needed
  to make that read authoritative.
  """

  alias SymphonyElixir.{ActionLedger.Action, Workspace}
  alias SymphonyElixir.Codex.AppServer

  @spec inspect(Action.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(%Action{} = action, opts \\ []) do
    reader = Keyword.get(opts, :thread_reader, &AppServer.read_thread/3)
    lister = Keyword.get(opts, :thread_lister, &AppServer.list_threads/2)

    with :ok <- task_creation_action(action) do
      inspect_correlation(action, reader, lister)
    end
  end

  defp inspect_correlation(action, reader, lister) do
    case correlation(action) do
      {:ok, correlation} ->
        inspect_exact(correlation, reader)

      {:error, {:recovery_correlation_missing, "thread_id"}} = missing ->
        if legacy_recovery_applicable?(action), do: inspect_legacy_zero_turn(action, lister), else: missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp legacy_recovery_applicable?(%Action{observed_effect: %{"disposition" => "restart_reconciliation_required"}}),
    do: true

  defp legacy_recovery_applicable?(_action), do: false

  defp inspect_exact(correlation, reader) do
    with {:ok, workspace} <- Workspace.path_for_key(correlation.workspace_key, correlation.worker_host),
         {:ok, thread} <- reader.(correlation.thread_id, workspace, worker_host: correlation.worker_host),
         :ok <- strict_match(thread, correlation, workspace) do
      {:ok,
       %{
         provider: "codex",
         authoritative: true,
         exists: true,
         session_correlation_id: correlation.session_correlation_id,
         workspace_key: correlation.workspace_key,
         disposition: "codex_thread_read_exact_match"
       }}
    else
      {:error, :thread_not_found} ->
        {:ok, %{provider: "codex", authoritative: true, exists: false, disposition: "codex_thread_read_absent"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inspect_legacy_zero_turn(%Action{observed_effect: effect, target: target}, lister)
       when is_map(effect) and is_map(target) do
    with {:ok, workspace_key} <- required(effect, "workspace_key"),
         true <- effect["disposition"] == "restart_reconciliation_required" or {:error, :legacy_recovery_not_applicable},
         {:ok, worker_host} <- legacy_worker_host(target),
         {:ok, workspace} <- Workspace.path_for_key(workspace_key, worker_host),
         {:ok, threads} <- lister.(workspace, worker_host: worker_host),
         {:ok, _thread} <- unique_legacy_zero_turn(threads, workspace) do
      {:ok,
       %{
         provider: "codex",
         authoritative: true,
         exists: true,
         workspace_key: workspace_key,
         disposition: "legacy_zero_turn_compensated"
       }}
    end
  end

  defp inspect_legacy_zero_turn(_action, _lister), do: {:error, :legacy_recovery_not_applicable}

  defp legacy_worker_host(%{"worker_host" => "local"}), do: {:ok, nil}
  defp legacy_worker_host(%{"worker_host" => host}) when is_binary(host) and host != "", do: {:ok, host}
  defp legacy_worker_host(%{"worker_host" => _invalid}), do: {:error, :legacy_host_invalid}
  defp legacy_worker_host(%{"type" => "codex_task"}), do: {:ok, nil}
  defp legacy_worker_host(_target), do: {:error, :legacy_host_invalid}

  defp unique_legacy_zero_turn(threads, workspace) when is_list(threads) do
    matches = Enum.filter(threads, &legacy_zero_turn?(&1, workspace))

    case matches do
      [thread] -> {:ok, thread}
      [] -> {:error, :legacy_zero_turn_not_found}
      _ -> {:error, :legacy_zero_turn_ambiguous}
    end
  end

  defp unique_legacy_zero_turn(_threads, _workspace), do: {:error, :legacy_thread_list_invalid}

  defp legacy_zero_turn?(thread, workspace) when is_map(thread) do
    status = thread["status"]
    turns = thread["turns"]

    thread["cwd"] == workspace and
      status in ["notLoaded", %{"type" => "notLoaded"}] and
      match?([%{"status" => "interrupted", "items" => []}], turns) and
      zero_usage?(thread) and Enum.all?(turns, &zero_usage?/1)
  end

  defp legacy_zero_turn?(_thread, _workspace), do: false

  defp zero_usage?(record) when is_map(record) do
    case record["usage"] || record["tokenUsage"] do
      nil -> true
      usage when is_map(usage) -> Enum.all?(Map.values(usage), &(&1 in [0, nil]))
      _ -> false
    end
  end

  defp task_creation_action(%Action{kind: :task_creation, expected_postcondition: "codex.session_observed"}), do: :ok
  defp task_creation_action(_action), do: {:error, :unsupported_recovery_action}

  defp correlation(%Action{observed_effect: effect}) when is_map(effect) do
    with {:ok, thread_id} <- required(effect, "thread_id"),
         {:ok, turn_id} <- required(effect, "turn_id"),
         {:ok, session_correlation_id} <- required(effect, "session_correlation_id"),
         {:ok, workspace_key} <- required(effect, "workspace_key"),
         {:ok, worker_host} <- host_assertion(effect),
         true <-
           session_correlation_id == "#{thread_id}-#{turn_id}" or
             {:error, :session_correlation_mismatch} do
      {:ok,
       %{
         thread_id: thread_id,
         turn_id: turn_id,
         session_correlation_id: session_correlation_id,
         workspace_key: workspace_key,
         worker_host: worker_host
       }}
    end
  end

  defp correlation(_action), do: {:error, :recovery_correlation_missing}

  defp required(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:recovery_correlation_missing, key}}
    end
  end

  # The App Server does not expose a provider session id.  This is therefore a
  # derived local correlation id, paired with a typed dispatch-host assertion;
  # it must never be presented as provider-issued session authority.
  defp host_assertion(map) do
    case Map.get(map, "host_assertion") do
      %{"type" => "worker_host", "value" => "local"} -> {:ok, nil}
      %{"type" => "worker_host", "value" => value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :host_assertion_invalid}
    end
  end

  defp strict_match(thread, correlation, workspace) when is_map(thread) do
    thread_id = Map.get(thread, "id") || Map.get(thread, :id)
    cwd = Map.get(thread, "cwd") || Map.get(thread, :cwd)
    turns = Map.get(thread, "turns") || Map.get(thread, :turns)

    case {thread_id == correlation.thread_id, cwd == workspace, turns} do
      {false, _, _} -> {:error, :thread_id_mismatch}
      {_, false, _} -> {:error, :workspace_mismatch}
      {_, _, turns} when not is_list(turns) -> {:error, :thread_turns_missing}
      {_, _, turns} -> match_turn(turns, correlation.turn_id)
    end
  end

  defp strict_match(_thread, _correlation, _workspace), do: {:error, :thread_payload_invalid}

  defp match_turn(turns, turn_id) do
    Enum.reduce_while(turns, :not_found, fn
      turn, _acc when is_map(turn) ->
        if (Map.get(turn, "id") || Map.get(turn, :id)) == turn_id,
          do: {:halt, :found},
          else: {:cont, :not_found}

      _malformed_turn, _acc ->
        {:halt, {:error, :thread_turn_payload_invalid}}
    end)
    |> case do
      :found -> :ok
      :not_found -> {:error, :turn_id_mismatch}
      {:error, _reason} = error -> error
    end
  end
end
