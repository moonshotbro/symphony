defmodule SymphonyElixir.Codex.ProviderCapacityRecoveryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.ProviderCapacityRecovery, as: Recovery

  test "classifies the installed turn failed payload without confusing quota or compaction" do
    assert Recovery.classify({:turn_failed, %{"error" => %{"codex_error_info" => "server_overloaded"}}}) == :provider_capacity
    assert Recovery.classify(%{"codex_error_info" => "usage_limit_reached"}) == :usage_limit
    assert Recovery.classify(%{"message" => "remote compaction context exhausted"}) == :context_exhaustion
    assert Recovery.classify(%{"message" => "permission denied"}) == :permission
  end

  test "does one same-route retry then follows Sol Terra Luna" do
    {:ok, sol} = Recovery.route(:"gpt-5.6-sol", :high)
    assert {:retry, ^sol} = Recovery.next_route(sol, 0)
    assert {:fallback, %{model: :"gpt-5.6-terra", effort: :high}} = Recovery.next_route(sol, 1)

    assert {:fallback, %{model: :"gpt-5.6-luna", effort: :high}} =
             Recovery.next_route(%{model: :"gpt-5.6-terra", effort: :high}, 1)

    assert :exhausted = Recovery.next_route(%{model: :"gpt-5.6-luna", effort: :medium}, 1)
    refute :"gpt-5.3-codex-spark" in Recovery.supported_models()
  end

  test "accepts string routes and rejects unsupported models or efforts" do
    assert {:ok, %{model: :"gpt-5.6-sol", effort: :high}} = Recovery.route("gpt-5.6-sol", "high")
    assert {:error, :unsupported_route} = Recovery.route("gpt-5.3-codex-spark", :high)
    assert {:error, :unsupported_route} = Recovery.route(:"gpt-5.6-sol", :bogus)
  end

  test "classifies network, input and generic failures" do
    assert Recovery.classify(%{"message" => "network connection timeout"}) == :network
    assert Recovery.classify(%{"message" => "input_required by elicitation"}) == :input_required
    assert Recovery.classify(%{"message" => "unexpected worker crash"}) == :worker_failure
  end

  test "capacity plans preserve recovery state and exhaust safely" do
    base = %{
      reason: %{"error" => %{"codex_error_info" => "server_overloaded"}},
      original: %{model: :"gpt-5.6-sol", effort: :high},
      attempt: 0,
      response_started: false
    }

    assert {:ok, %{same_route_retry: true, goal_state: :recovering_provider_capacity}} = Recovery.plan(Map.put(base, :attempt, 0))
    assert {:ok, %{effective: %{model: :"gpt-5.6-terra"}}} = Recovery.plan(Map.put(base, :attempt, 1))
    exhausted = %{base | original: %{model: :"gpt-5.6-luna", effort: :medium}, attempt: 1}
    assert {:ok, %{goal_state: :attention_required}} = Recovery.plan(exhausted)
    assert {:error, :not_capacity_failure} = Recovery.plan(%{base | reason: :worker_crashed, attempt: 0})
  end

  test "bounded traversal handles malformed and deeply nested payloads" do
    assert Recovery.classify({:turn_failed, [%{"message" => "server overloaded"}]}) == :provider_capacity
    nested = Enum.reduce(1..14, "server_overloaded", fn _, value -> %{nested: value} end)
    assert Recovery.classify(nested) == :worker_failure
  end

  test "uncertain provider effect is held for reconciliation" do
    assert {:error, :uncertain_effect} =
             Recovery.plan(%{
               reason: %{"codex_error_info" => "server_overloaded"},
               original: %{model: :"gpt-5.6-sol", effort: :high},
               attempt: 0,
               response_started: true
             })
  end

  test "redaction retains correlation and route evidence only" do
    evidence =
      Recovery.redact(%{task_id: "task", goal_id: "goal", operation_id: "op", idempotency_key: "key", prompt: "secret", tool_payload: "secret", effective: %{model: :"gpt-5.6-terra", effort: :high}})

    assert evidence == %{
             task_id: "task",
             goal_id: "goal",
             operation_id: "op",
             idempotency_key: "key",
             effective: %{model: :"gpt-5.6-terra", effort: :high}
           }
  end

  test "backoff is deterministic when jitter is injected" do
    assert Recovery.delay_ms(2, 100, 0.25, fn -> 0.5 end) == 450
    assert is_integer(Recovery.delay_ms(0, 10, 0.0))
  end

  test "ignores non-text payload leaves" do
    assert Recovery.classify(%{error: 123, nested: nil}) == :worker_failure
  end
end
