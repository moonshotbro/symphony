defmodule SymphonyElixir.Codex.ProviderCapacityRecovery do
  @moduledoc """
  Typed, privacy-safe policy for recovering Codex provider-capacity failures.

  This module is deliberately side-effect free.  The orchestrator owns durable
  persistence and dispatch; it uses this policy to classify the actual
  `turn/failed` payload, choose a governed route, and decide whether a
  response may be retried.
  """

  @models [:"gpt-5.6-sol", :"gpt-5.6-terra", :"gpt-5.6-luna"]
  @fallback_order [:"gpt-5.6-sol", :"gpt-5.6-terra", :"gpt-5.6-luna"]
  @efforts [:low, :medium, :high, :xhigh, :max, :ultra]
  @capacity_markers ["server_overloaded", "server overloaded"]
  @max_payload_depth 12

  @type model :: :"gpt-5.6-sol" | :"gpt-5.6-terra" | :"gpt-5.6-luna"
  @type effort :: :low | :medium | :high | :xhigh | :max | :ultra
  @type failure_class ::
          :provider_capacity
          | :usage_limit
          | :context_exhaustion
          | :network
          | :permission
          | :input_required
          | :worker_failure

  @type route :: %{model: model(), effort: effort()}
  @type recovery :: %{
          original: route(),
          effective: route(),
          attempt: non_neg_integer(),
          same_route_retry: boolean(),
          failure_class: failure_class(),
          response_started: boolean(),
          reconcile_before_dispatch: boolean(),
          goal_state: :recovering_provider_capacity | :attention_required
        }

  @spec supported_models() :: [model()]
  def supported_models, do: @models

  @spec classify(term()) :: failure_class()
  def classify(reason) do
    values = payload_values(reason, 0)

    cond do
      Enum.any?(values, &capacity_marker?/1) -> :provider_capacity
      Enum.any?(values, &contains_any?(&1, ["usage", "quota", "rate_limit", "rate limit", "credits"])) -> :usage_limit
      Enum.any?(values, &contains_any?(&1, ["context", "compaction", "token limit", "prompt too long"])) -> :context_exhaustion
      Enum.any?(values, &contains_any?(&1, ["permission", "forbidden", "unauthorized", "approval"])) -> :permission
      Enum.any?(values, &contains_any?(&1, ["input_required", "input required", "elicitation"])) -> :input_required
      Enum.any?(values, &contains_any?(&1, ["network", "timeout", "connection", "transport"])) -> :network
      true -> :worker_failure
    end
  end

  @spec route(model() | atom() | String.t(), effort() | atom() | String.t()) ::
          {:ok, route()} | {:error, :unsupported_route}
  def route(model, effort) do
    with {:ok, model} <- normalize_model(model),
         {:ok, effort} <- normalize_effort(effort) do
      {:ok, %{model: model, effort: effort}}
    else
      _ -> {:error, :unsupported_route}
    end
  end

  @spec next_route(route(), non_neg_integer()) :: {:retry, route()} | {:fallback, route()} | :exhausted
  def next_route(%{model: model, effort: effort}, attempt) when is_integer(attempt) and attempt >= 0 do
    case {model, attempt} do
      {model, 0} -> {:retry, %{model: model, effort: effort}}
      {model, _} -> fallback_route(model, effort)
    end
  end

  @spec fallback_route(model(), effort()) :: {:fallback, route()} | :exhausted
  def fallback_route(model, effort) do
    case Enum.drop_while(@fallback_order, &(&1 != model)) do
      [_current, next_model | _] -> {:fallback, %{model: next_model, effort: governed_effort(next_model, effort)}}
      _ -> :exhausted
    end
  end

  @spec delay_ms(non_neg_integer(), non_neg_integer(), float(), (-> float())) :: non_neg_integer()
  def delay_ms(attempt, base_ms, jitter_ratio, random \\ &:rand.uniform/0)
      when is_integer(attempt) and attempt >= 0 and is_integer(base_ms) and base_ms >= 0 and
             is_float(jitter_ratio) and jitter_ratio >= 0.0 and is_function(random, 0) do
    exponential = base_ms * Integer.pow(2, min(attempt, 30))
    jitter = round(exponential * jitter_ratio * random.())
    exponential + jitter
  end

  @spec plan(map()) :: {:ok, recovery()} | {:error, :not_capacity_failure | :uncertain_effect}
  def plan(%{reason: reason, original: original, attempt: attempt, response_started: response_started}) do
    case classify(reason) do
      :provider_capacity when response_started == false ->
        with {:ok, original} <- route(original[:model], original[:effort]) do
          decision = next_route(original, attempt)
          {:ok, plan_from_decision(original, decision, attempt, false)}
        end

      :provider_capacity ->
        {:error, :uncertain_effect}

      _ ->
        {:error, :not_capacity_failure}
    end
  end

  @spec redact(map()) :: map()
  def redact(evidence) when is_map(evidence) do
    Map.take(evidence, [
      :task_id,
      :goal_id,
      :operation_id,
      :idempotency_key,
      :original,
      :effective,
      :attempt,
      :delay_ms,
      :resume_at,
      :failure_class,
      :response_started,
      :recovery_outcome,
      :goal_state,
      :circuit_state,
      :attempted_routes
    ])
  end

  defp plan_from_decision(original, {:retry, effective}, attempt, reconcile) do
    %{
      original: original,
      effective: effective,
      attempt: attempt + 1,
      same_route_retry: true,
      failure_class: :provider_capacity,
      response_started: false,
      reconcile_before_dispatch: reconcile,
      goal_state: :recovering_provider_capacity
    }
  end

  defp plan_from_decision(original, {:fallback, effective}, attempt, reconcile) do
    %{
      original: original,
      effective: effective,
      attempt: attempt + 1,
      same_route_retry: false,
      failure_class: :provider_capacity,
      response_started: false,
      reconcile_before_dispatch: reconcile,
      goal_state: :recovering_provider_capacity
    }
  end

  defp plan_from_decision(original, :exhausted, attempt, reconcile) do
    %{
      original: original,
      effective: original,
      attempt: attempt,
      same_route_retry: false,
      failure_class: :provider_capacity,
      response_started: false,
      reconcile_before_dispatch: reconcile,
      goal_state: :attention_required
    }
  end

  defp governed_effort(_model, effort), do: effort

  defp normalize_model(model) when model in @models, do: {:ok, model}

  defp normalize_model(model) when is_binary(model) do
    model |> String.trim() |> String.to_atom() |> normalize_model()
  end

  defp normalize_model(_), do: {:error, :unsupported_route}

  defp normalize_effort(effort) when effort in @efforts, do: {:ok, effort}
  defp normalize_effort(effort) when is_binary(effort), do: normalize_effort(String.to_atom(String.trim(effort)))
  defp normalize_effort(_), do: {:error, :unsupported_route}

  defp payload_values(_payload, depth) when depth > @max_payload_depth, do: []

  defp payload_values(payload, depth) when is_tuple(payload),
    do: payload |> Tuple.to_list() |> Enum.flat_map(&payload_values(&1, depth + 1))

  defp payload_values(payload, depth) when is_map(payload),
    do: [
      payload |> Map.keys() |> Enum.map_join(" ", &to_string/1)
      | Enum.flat_map(payload, fn {key, value} ->
          payload_values(key, depth + 1) ++ payload_values(value, depth + 1)
        end)
    ]

  defp payload_values(payload, depth) when is_list(payload), do: Enum.flat_map(payload, &payload_values(&1, depth + 1))
  defp payload_values(payload, _depth) when is_atom(payload), do: [Atom.to_string(payload)]
  defp payload_values(payload, _depth) when is_binary(payload), do: [payload]
  defp payload_values(_payload, _depth), do: []

  defp capacity_marker?(value) do
    normalized = String.downcase(value)
    Enum.any?(@capacity_markers, &String.contains?(normalized, &1))
  end

  defp contains_any?(value, markers) do
    normalized = String.downcase(value)
    Enum.any?(markers, &String.contains?(normalized, &1))
  end
end
