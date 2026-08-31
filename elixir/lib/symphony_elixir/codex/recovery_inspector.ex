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

    with :ok <- task_creation_action(action),
         {:ok, correlation} <- correlation(action),
         {:ok, workspace} <- Workspace.path_for_key(correlation.workspace_key, correlation.worker_host),
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
