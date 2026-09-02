defmodule SymphonyElixir.WorkPressure do
  @moduledoc """
  Pure, deterministic selection of ready work for the Symphony conductor.

  This module is intentionally a selector, not a scheduler.  It consumes
  already-normalized graph and ledger facts and returns bounded dispatch
  proposals.  A caller remains responsible for validating a
  `TaskLaunchContract` and recording effects in `ActionLedger` before any
  provider or workspace effect is attempted.

  The same decision revision and facts always produce the same constructor
  identity and selection order.  Capacity is represented as held work rather
  than as a retryable failure, so a full system does not create retry storms.
  """

  @required_item_keys ~w(issue_id task_id project_id repository write_domain role exact_revision idempotency_key)a
  @optional_item_keys ~w(priority host fence_epoch)a
  @required_limit_keys ~w(global host project repository write_domain)a

  @type item :: %{
          required(:issue_id) => String.t(),
          required(:task_id) => String.t(),
          required(:project_id) => String.t(),
          required(:repository) => String.t(),
          required(:write_domain) => String.t(),
          required(:role) => String.t(),
          required(:exact_revision) => String.t(),
          required(:idempotency_key) => String.t(),
          optional(:priority) => integer(),
          optional(:host) => String.t(),
          optional(:fence_epoch) => non_neg_integer()
        }

  @type result :: %{
          constructor_action_id: String.t(),
          decision_revision: String.t(),
          selected: [item()],
          held: [%{item: item(), reason: atom()}],
          available: non_neg_integer(),
          target: non_neg_integer()
        }

  @doc "Select ready items up to the safe target, preserving deterministic order."
  @spec select([item()], [item()], map(), String.t()) :: {:ok, result()} | {:error, atom()}
  def select(ready, active, limits, decision_revision)
      when is_list(ready) and is_list(active) and is_map(limits) and is_binary(decision_revision) and
             decision_revision != "" do
    with :ok <- validate_items(ready),
         :ok <- validate_items(active),
         :ok <- validate_limits(limits),
         :ok <- validate_revision(decision_revision),
         :ok <- reject_duplicate_ownership(active),
         {:ok, target} <- target(limits),
         active_count = length(active),
         available = max(target - active_count, 0) do
      ordered = Enum.sort_by(ready, &ordering_key/1)
      {selected, held} = choose(ordered, active, available, limits)

      {:ok,
       %{
         constructor_action_id: constructor_id(decision_revision, ready, active, limits),
         decision_revision: decision_revision,
         selected: selected,
         held: held,
         available: available,
         target: target
       }}
    end
  end

  def select(_ready, _active, _limits, _revision), do: {:error, :input_invalid}

  defp validate_revision(value) do
    if byte_size(value) <= 256 and not String.contains?(value, ["\n", "\r", "\0"]),
      do: :ok,
      else: {:error, :revision_invalid}
  end

  defp validate_items(items) do
    if length(items) > 256 do
      {:error, :items_too_many}
    else
      items
      |> Enum.reduce_while({:ok, MapSet.new()}, fn item, {:ok, seen} ->
        case validate_item(item, seen) do
          {:ok, next_seen} -> {:cont, {:ok, next_seen}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, _seen} -> :ok
        error -> error
      end
    end
  end

  defp validate_item(item, seen) when is_map(item) do
    keys = Map.keys(item)

    with :ok <- required_keys(keys),
         :ok <- optional_keys(keys),
         :ok <- validate_item_values(item),
         identity = item_identity(item),
         false <- MapSet.member?(seen, identity) do
      {:ok, MapSet.put(seen, identity)}
    else
      true -> {:error, :duplicate_item}
      {:error, _} = error -> error
      _ -> {:error, :item_invalid}
    end
  end

  defp validate_item(_item, _seen), do: {:error, :item_invalid}

  defp required_keys(keys) do
    if Enum.all?(@required_item_keys, &(&1 in keys)), do: :ok, else: {:error, :item_required_key_missing}
  end

  defp optional_keys(keys) do
    allowed = @required_item_keys ++ @optional_item_keys
    if Enum.all?(keys, &(&1 in allowed)), do: :ok, else: {:error, :item_unknown_key}
  end

  defp validate_item_values(item) do
    string_keys = ~w(issue_id task_id project_id repository write_domain role exact_revision idempotency_key host)a

    cond do
      Enum.any?(string_keys, fn key -> Map.has_key?(item, key) and not valid_text?(item[key]) end) ->
        {:error, :item_text_invalid}

      Map.has_key?(item, :priority) and not is_integer(item.priority) ->
        {:error, :priority_invalid}

      Map.has_key?(item, :fence_epoch) and
          (not is_integer(item.fence_epoch) or item.fence_epoch < 0) ->
        {:error, :fence_epoch_invalid}

      true -> :ok
    end
  end

  defp validate_limits(limits) do
    if Map.keys(limits) |> Enum.all?(&(&1 in @required_limit_keys)) and
         Enum.all?(@required_limit_keys, fn key -> valid_limit?(Map.get(limits, key)) end) do
      :ok
    else
      {:error, :limits_invalid}
    end
  end

  defp valid_limit?(value) when is_integer(value) and value >= 0, do: true
  defp valid_limit?(value) when is_map(value), do: Enum.all?(value, fn {key, limit} -> valid_text?(to_string(key)) and valid_limit?(limit) end)
  defp valid_limit?(_value), do: false

  defp target(limits) do
    global = Map.fetch!(limits, :global)
    if is_integer(global), do: {:ok, global}, else: {:error, :global_limit_invalid}
  end

  defp reject_duplicate_ownership(active) do
    identities = Enum.map(active, &ownership_key/1)
    if length(identities) == length(Enum.uniq(identities)), do: :ok, else: {:error, :duplicate_writer}
  end

  defp choose(ordered, active, available, limits) do
    occupied = Enum.map(active, &ownership_key/1) |> MapSet.new()

    Enum.reduce(ordered, {[], []}, fn item, {selected, held} ->
      cond do
        item_identity(item) in Enum.map(selected, &item_identity/1) ->
          {selected, held}

        MapSet.member?(occupied, ownership_key(item)) ->
          {selected, held ++ [%{item: item, reason: :write_domain_held}]}

        length(selected) < available and capacity_available?(item, active, selected, limits) ->
          {selected ++ [item], held}

        true ->
          reason = if length(selected) >= available, do: :capacity_held, else: :dimension_held
          {selected, held ++ [%{item: item, reason: reason}]}
      end
    end)
  end

  defp ordering_key(item), do: {-Map.get(item, :priority, 0), item.issue_id, item.idempotency_key}

  defp capacity_available?(item, active, selected, limits) do
    occupants = active ++ selected
    Enum.all?(
      [{:host, :host}, {:project, :project_id}, {:repository, :repository}, {:write_domain, :write_domain}],
      fn {limit_key, item_key} ->
        ceiling = limit_for(Map.fetch!(limits, limit_key), Map.get(item, item_key))
        is_nil(ceiling) or count_dimension(occupants, item_key, Map.get(item, item_key)) < ceiling
      end
    )
  end

  defp limit_for(value, _dimension) when is_integer(value), do: value
  defp limit_for(value, dimension) when is_map(value) do
    Map.get(value, dimension) || Map.get(value, to_string(dimension))
  end
  defp limit_for(_value, _dimension), do: nil

  defp count_dimension(items, key, value), do: Enum.count(items, &(Map.get(&1, key) == value))

  defp item_identity(item), do: {item.issue_id, item.task_id, item.idempotency_key}
  defp ownership_key(item), do: {item.repository, item.write_domain}

  defp constructor_id(revision, ready, active, limits) do
    payload = :erlang.term_to_binary({revision, Enum.sort_by(ready, &ordering_key/1), Enum.sort_by(active, &ordering_key/1), limits})
    "constructor-" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  defp valid_text?(value) when is_binary(value) do
    byte_size(value) in 1..256 and not String.contains?(value, ["\n", "\r", "\0"])
  end

  defp valid_text?(_value), do: false
end
