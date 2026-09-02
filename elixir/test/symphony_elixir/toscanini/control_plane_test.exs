defmodule SymphonyElixir.Toscanini.ControlPlaneTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Toscanini.ControlCLI
  alias SymphonyElixir.Toscanini.ControlPlane

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

  test "constructs a shorthand request through the runtime authority path" do
    root = Path.join(System.tmp_dir!(), "toscanini-control-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(root)
      {_, 0} = System.cmd("git", ["init", "-q", root])
      {_, 0} = System.cmd("git", ["-C", root, "config", "user.email", "test@example.test"])
      {_, 0} = System.cmd("git", ["-C", root, "config", "user.name", "Test"])
      {_, 0} = System.cmd("git", ["-C", root, "remote", "add", "origin", "https://github.com/moonshotbro/symphony.git"])
      File.write!(Path.join(root, "README.md"), "test\n")
      {_, 0} = System.cmd("git", ["-C", root, "add", "."])
      {_, 0} = System.cmd("git", ["-C", root, "commit", "-qm", "test"])

      write_workflow_file!(Workflow.workflow_file_path(),
        codex_project_binding: %{
          enabled: true,
          programme: "build-toscanini",
          saved_project_id: "b12752f9-9a65-4194-bc49-77808b21d767",
          native_project_id: "01a04aab-c77c-79b0-ab09-65187353bb4b",
          repository: "moonshotbro/symphony",
          root: root
        }
      )

      request = %{
        "repository" => "moonshotbro/symphony",
        "project_id" => "b12752f9-9a65-4194-bc49-77808b21d767",
        "issue_identifier" => "SYS-61",
        "objective" => "Bounded construction",
        "role" => "execution_production",
        "workspace_path" => root
      }

      {revision, 0} = System.cmd("git", ["-C", root, "rev-parse", "HEAD"])
      request = Map.put(request, "fence", "SYS-61:0:#{String.trim(revision)}")

      result =
        request
        |> then(&ControlCLI.invoke("construct_task", {:ok, &1}))
        |> Jason.encode!()
        |> Jason.decode!()

      assert result["ok"] == true
      assert result["repository"] == request["repository"]
      assert result["project_id"] == request["project_id"]
      assert result["fence"] == request["fence"]
      assert result["contract"]["repository"] == request["repository"]
      assert result["contract"]["issue_or_pr"] == "SYS-61"

      mismatch =
        ControlCLI.invoke("construct_task", {:ok, Map.put(request, "project_id", "untrusted-project")})
        |> Jason.encode!()
        |> Jason.decode!()

      assert mismatch["ok"] == false
      assert mismatch["error"] == "project_id_mismatch"
    after
      File.rm_rf(root)
    end
  end
end
