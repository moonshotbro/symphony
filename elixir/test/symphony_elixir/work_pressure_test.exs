defmodule SymphonyElixir.WorkPressureTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkPressure

  @limits %{global: 2, host: 2, project: 2, repository: 2, write_domain: 1}

  defp item(id, opts \\ []) do
    Map.merge(
      %{
        issue_id: "issue-#{id}",
        task_id: "task-#{id}",
        project_id: "project-1",
        repository: "repo-1",
        write_domain: "domain-#{id}",
        role: "implementation",
        authority_revision: "rev-#{id}",
        idempotency_key: "dispatch-#{id}"
      },
      Map.new(opts)
    )
  end

  test "selects by priority and never exceeds target" do
    ready = [item("b", priority: 1), item("a", priority: 2), item("c", priority: 0)]
    assert {:ok, result} = WorkPressure.select(ready, [], @limits, "graph-1")
    assert Enum.map(result.selected, & &1.issue_id) == ["issue-a", "issue-b"]
    assert Enum.map(result.held, & &1.reason) == [:capacity_held]
    assert result.available == 2
  end

  test "constructor identity and result are stable on replay" do
    input = [item("a"), item("b")]
    assert {:ok, first} = WorkPressure.select(input, [], @limits, "graph-1")
    assert {:ok, replay} = WorkPressure.select(Enum.reverse(input), [], @limits, "graph-1")
    assert first == replay
  end

  test "full capacity is managed backpressure" do
    active = [item("a"), item("b")]
    assert {:ok, result} = WorkPressure.select([item("c")], active, @limits, "graph-2")
    assert result.selected == []
    assert [%{reason: :capacity_held}] = result.held
    assert result.available == 0
  end

  test "refill selects work after a lease is released" do
    assert {:ok, result} = WorkPressure.select([item("a"), item("b")], [item("active")], @limits, "graph-3")
    assert length(result.selected) == 1
    assert result.available == 1
  end

  test "write-domain conflict is held without a second writer" do
    active = [item("active", write_domain: "shared")]
    ready = [item("a", write_domain: "shared"), item("b", write_domain: "free")]
    assert {:ok, result} = WorkPressure.select(ready, active, @limits, "graph-4")
    assert Enum.map(result.selected, & &1.issue_id) == ["issue-b"]
    assert [%{reason: :write_domain_held}] = result.held
  end

  test "malformed facts fail closed" do
    assert {:error, :item_unknown_key} = WorkPressure.select([Map.put(item("a"), :prompt, "bad")], [], @limits, "graph-1")
    assert {:error, :duplicate_writer} = WorkPressure.select([], [item("a", write_domain: "same"), item("b", write_domain: "same")], @limits, "graph-1")
    assert {:error, :limits_invalid} = WorkPressure.select([], [], Map.put(@limits, :global, -1), "graph-1")
    assert {:error, :input_invalid} = WorkPressure.select(:invalid, [], @limits, "graph-1")
    assert {:error, :duplicate_item} = WorkPressure.select([item("a"), item("a")], [], @limits, "graph-1")
    assert {:error, :item_invalid} = WorkPressure.select([:invalid], [], @limits, "graph-1")
    assert {:error, :item_text_invalid} = WorkPressure.select([%{item("a") | role: ""}], [], @limits, "graph-1")
    assert {:error, :item_text_invalid} = WorkPressure.select([%{item("a") | role: 1}], [], @limits, "graph-1")
    assert {:error, :global_limit_invalid} = WorkPressure.select([], [], Map.put(@limits, :global, %{}), "graph-1")
  end

  test "dimension maps hold work at their configured boundary" do
    limits = %{@limits | host: %{"host-1" => 0}, project: %{}, repository: %{}, write_domain: %{}}
    assert {:ok, result} = WorkPressure.select([item("a", host: "host-1")], [], limits, "graph-map")
    assert [%{reason: :dimension_held}] = result.held
    assert result.selected == []
  end
end
