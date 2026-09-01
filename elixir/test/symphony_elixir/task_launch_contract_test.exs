defmodule SymphonyElixir.Codex.TaskLaunchContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.TaskLaunchContract

  test "compiles a deterministic, project-bound worker contract" do
    attrs = valid_attrs()
    assert {:ok, first} = TaskLaunchContract.compile(attrs)
    assert {:ok, second} = TaskLaunchContract.compile(Map.put(attrs, :title, "ignored"))
    assert first.contract_id == second.contract_id
    assert first.title == "Implementation SYS-50: define contract"
    assert first.project.saved_project_id == "b12752f9-9a65-4194-bc49-77808b21d767"
  end

  test "rejects missing or mismatched project namespaces" do
    assert {:error, errors} = TaskLaunchContract.compile(put_in(valid_attrs(), [:project, :native_project_id], "b12752f9-9a65-4194-bc49-77808b21d767"))
    assert :project_namespaces_must_be_distinct in errors

    assert {:error, errors} = TaskLaunchContract.compile(Map.delete(valid_attrs(), :project))
    assert {:missing, :project} in errors
  end

  test "enforces role and goal policy boundaries" do
    assert {:error, errors} = TaskLaunchContract.compile(%{valid_attrs() | role: :landing, goal_policy: :worker})
    assert :role_requires_no_goal in errors

    assert {:error, errors} = TaskLaunchContract.compile(%{valid_attrs() | model: "unsupported"})
    assert {:unsupported_model, nil} in errors
  end

  test "detects duplicate identity in a batch while allowing distinct attempts" do
    assert {:error, [:duplicate_contract_identity]} = TaskLaunchContract.compile_many([valid_attrs(), valid_attrs()])
    assert {:ok, contracts} = TaskLaunchContract.compile_many([valid_attrs(), %{valid_attrs() | attempt: 1}])
    assert Enum.map(contracts, & &1.contract_id) |> Enum.uniq() |> length() == 2
  end

  defp valid_attrs do
    %{
      programme: "build-toscanini",
      repository: "moonshotbro/sysmiq-symphony",
      issue_or_pr: "SYS-50",
      role: :implementation,
      task: "define contract",
      attempt: 0,
      fence: "lease-50-1",
      exact_revision: "3d3ee035725b0728f041d8d10fc29f5c8adc42c0",
      write_boundary: :product,
      evidence: ["issue-50"],
      model: :"gpt-5.6-luna",
      goal_policy: :worker,
      project: %{
        saved_project_id: "b12752f9-9a65-4194-bc49-77808b21d767",
        native_project_id: "01a04aab-c77c-79b0-ab09-65187353bb4b",
        repository: "moonshotbro/sysmiq-symphony",
        root: "/Users/sysmiq/sysmiq-symphony"
      }
    }
  end
end
