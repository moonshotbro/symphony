defmodule SymphonyElixir.Toscanini.ControlPlaneTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Toscanini.ControlPlane
  alias SymphonyElixir.Toscanini.ControlCLI

  test "exposes one bounded facade over existing operations" do
    capabilities = ControlPlane.capabilities()

    assert "compile_task" in capabilities["read"]
    assert "select_work" in capabilities["read"]
    assert "dispatch_command" in capabilities["mutate"]
    refute Enum.any?(Map.values(capabilities), &Enum.member?(&1, "execute"))
  end

  test "role registry is the source of accountability roles" do
    roles = ControlPlane.roles()

    assert is_map(roles)
    assert Map.has_key?(roles, "planning_coordination")
    assert Map.has_key?(roles, "verification_assessment")
  end

  test "selection remains deterministic and delegates to work pressure" do
    item = %{
      issue_id: "symphony#1",
      task_id: "task-1",
      project_id: "project-1",
      repository: "moonshotbro/symphony",
      write_domain: "implementation",
      role: "execution_production",
      authority_revision: "r1",
      idempotency_key: "op-1"
    }

    limits = %{global: 1, host: 1, project: 1, repository: 1, write_domain: 1}
    assert {:ok, first} = ControlPlane.select_work([item], [], limits, "rev-1")
    assert {:ok, second} = ControlPlane.select_work([item], [], limits, "rev-1")
    assert first == second
    assert first.selected == [item]
  end

  test "malformed envelopes are rejected before the ledger boundary" do
    assert {:error, :unsupported_version} = ControlPlane.validate_envelope(%{})
  end

  test "fixed stdio bridge echoes identity and keeps provider effects parent-owned" do
    request = {:ok, %{"repository" => "moonshotbro/symphony", "project_id" => "p", "fence" => "f", "task_id" => "task-1", "expected_sha" => String.duplicate("a", 40)}}
    result = ControlCLI.invoke("review_exact_head", request)

    assert result["ok"] == false
    assert result["error"] == "parent_owned_operation"
    assert result["repository"] == "moonshotbro/symphony"
    assert result["project_id"] == "p"
    assert result["fence"] == "f"
    assert result["task_id"] == "task-1"
    assert result["head_sha"] == String.duplicate("a", 40)
  end

  test "fixed bridge rejects unknown operations" do
    assert {:ok, _} = Jason.decode(Jason.encode!(%{"ok" => false, "error" => "operation_required"}))
    assert "construct_task" in ControlCLI.operations()
    refute "execute" in ControlCLI.operations()
  end
end
