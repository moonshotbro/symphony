defmodule SymphonyElixir.Codex.TaskLaunchContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.TaskLaunchContract

  test "runtime compiler derives enabled binding from authority and rejects non-repositories" do
    root = Path.join(System.tmp_dir!(), "symphony-contract-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["init", "-q", root])
    {_, 0} = System.cmd("git", ["-C", root, "config", "user.email", "test@example.test"])
    {_, 0} = System.cmd("git", ["-C", root, "config", "user.name", "Test"])
    {_, 0} = System.cmd("git", ["-C", root, "remote", "add", "origin", "https://github.com/moonshotbro/sysmiq-symphony.git"])
    File.write!(Path.join(root, "README.md"), "test\n")
    {_, 0} = System.cmd("git", ["-C", root, "add", "."])
    {_, 0} = System.cmd("git", ["-C", root, "commit", "-qm", "test"])

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        codex_project_binding: %{
          enabled: true,
          programme: "build-toscanini",
          saved_project_id: "b12752f9-9a65-4194-bc49-77808b21d767",
          native_project_id: "01a04aab-c77c-79b0-ab09-65187353bb4b",
          repository: "moonshotbro/sysmiq-symphony",
          root: root
        }
      )

      issue = %SymphonyElixir.Tracker.Issue{identifier: "SYS-50", title: "Bound worker"}
      {revision, 0} = System.cmd("git", ["-C", root, "rev-parse", "HEAD"])
      runtime_ref = runtime_risk_receipt_ref(String.trim(revision))

      assert {:ok, contract} =
               TaskLaunchContract.from_runtime(issue, root,
                 trigger: :integration_design,
                 commissioning_identity: %{kind: "human", authority: "programme"},
                 risk_receipt_ref: runtime_ref,
                 risk_receipt_resolver: fn ^runtime_ref -> runtime_ref end
               )

      assert contract.executing_identity.model == :"gpt-5.6-terra"
      assert contract.project.saved_project_id != contract.project.native_project_id
      assert contract.risk_receipt_ref["required_gate_ids"] == ["project-bound-readback"]
      assert TaskLaunchContract.prompt(contract, "work") =~ contract.contract_id

      assert {:error, :risk_receipt_authority_mismatch} =
               TaskLaunchContract.from_runtime(issue, root,
                 risk_receipt_ref: runtime_ref,
                 risk_receipt_resolver: fn ref -> Map.put(ref, "authority_digest", String.duplicate("d", 64)) end
               )

      assert {:error, :risk_receipt_authority_unavailable} =
               TaskLaunchContract.from_runtime(issue, root, risk_receipt_ref: runtime_ref)

      assert {:error, :workspace_revision_unavailable} = TaskLaunchContract.from_runtime(issue, Path.join(root, "missing"))
    after
      File.rm_rf(root)
    end
  end

  test "title is total for malformed inputs" do
    assert TaskLaunchContract.title(self()) == "Symphony task"
    assert TaskLaunchContract.title(%{role: self(), task: %{bad: true}}) == "Task work: task"
  end

  test "repository task mode cannot fall back to a disabled project binding" do
    issue = %SymphonyElixir.Tracker.Issue{identifier: "SYS-50", title: "Bound worker"}

    assert {:error, :project_binding_required_for_repository_task} =
             TaskLaunchContract.from_runtime(issue, System.tmp_dir!(), repository_task: true)
  end

  test "escalation and post-resolution links are typed and immutable" do
    prior = "tlc-" <> String.duplicate("a", 64)

    link = %{
      prior_contract_id: prior,
      prior_task_id: "review-50",
      prior_role: :independent_review,
      prior_model: :"gpt-5.6-luna",
      prior_effort: :medium,
      trigger: :integration_design,
      reason: "provider boundary"
    }

    assert {:error, errors} = TaskLaunchContract.compile(Map.merge(valid_attrs(), %{model: :"gpt-5.6-terra", trigger: :integration_design}))
    assert :escalation_link_required in errors

    assert {:ok, terra} = TaskLaunchContract.compile(Map.merge(valid_attrs(), %{model: :"gpt-5.6-terra", trigger: :integration_design, escalation: link}))
    assert terra.executing_identity.model == :"gpt-5.6-terra"
    assert terra.executing_identity.contract_id == terra.contract_id

    assert {:ok, luna} = TaskLaunchContract.compile(Map.merge(valid_attrs(), %{task: "verify escalation", supersedes: %{contract_id: terra.contract_id, resolution: "ambiguity resolved"}}))
    refute luna.contract_id == terra.contract_id
    assert luna.supersedes["contract_id"] == terra.contract_id
  end

  test "compiles a deterministic, project-bound worker contract" do
    attrs = valid_attrs()
    assert {:ok, first} = TaskLaunchContract.compile(attrs)
    assert {:ok, second} = TaskLaunchContract.compile(attrs)
    assert first.contract_id == second.contract_id
    assert first.title == "Implementation SYS-50: define contract"
    assert first.project.saved_project_id == "b12752f9-9a65-4194-bc49-77808b21d767"
    assert {:ok, ^first} = TaskLaunchContract.verify(first)
    assert {:error, :invalid_task_launch_contract} = TaskLaunchContract.verify(%TaskLaunchContract{project: %{native_project_id: "forged"}})
  end

  test "rejects missing or mismatched project namespaces" do
    assert {:error, errors} = TaskLaunchContract.compile(put_in(valid_attrs(), [:project, :native_project_id], "b12752f9-9a65-4194-bc49-77808b21d767"))
    assert :project_namespaces_must_be_distinct in errors

    assert {:error, errors} = TaskLaunchContract.compile(Map.delete(valid_attrs(), :project))
    assert {:missing, :project} in errors

    assert {:error, errors} = TaskLaunchContract.compile(%{valid_attrs() | exact_revision: String.duplicate("a", 39)})
    assert :invalid_exact_revision in errors
  end

  test "accepts an exact-head risk receipt reference and binds its gates" do
    ref = risk_receipt_ref()
    assert {:ok, contract} = TaskLaunchContract.compile(Map.put(valid_attrs(), :risk_receipt_ref, ref))
    assert contract.risk_receipt_ref["head_sha"] == contract.exact_revision
    assert contract.risk_receipt_ref["required_gate_ids"] == contract.evidence_gates
    assert {:ok, ^contract} = TaskLaunchContract.verify(contract)
  end

  test "rejects malformed, stale, mismatched, or unresolved risk receipt references" do
    ref = risk_receipt_ref()

    for invalid <- [
          Map.put(ref, "head_sha", String.duplicate("b", 40)),
          Map.put(ref, "repository", "other/repository"),
          Map.put(ref, "required_gate_ids", ["review"]),
          Map.put(ref, "digest", "not-a-digest"),
          Map.put(ref, "unresolved_judgments", ["authority unclear"]),
          Map.put(ref, "escalation_required", true),
          Map.put(ref, "unexpected", "field")
        ] do
      assert {:error, errors} = TaskLaunchContract.compile(Map.put(valid_attrs(), :risk_receipt_ref, invalid))
      assert :invalid_risk_receipt_ref in errors
    end

    assert {:error, errors} = TaskLaunchContract.compile(Map.put(valid_attrs(), :risk_receipt_ref, "malformed"))
    assert :invalid_risk_receipt_ref in errors
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

  test "identity changes for every authority-bearing dimension" do
    {:ok, base} = TaskLaunchContract.compile(valid_attrs())

    for {key, value} <- [
          {:task, "other"},
          {:goal_policy, :none},
          {:dependencies, ["SYS-49"]},
          {:permissions, ["read-only"]},
          {:evidence_gates, ["review"]},
          {:evidence, ["different"]},
          {:stall_policy, :bounded},
          {:closeout_policy, :archive_exact},
          {:idempotency_identity, "other"},
          {:conflict_identity, "other"}
        ] do
      attrs = Map.put(valid_attrs(), key, value)
      assert {:ok, changed} = TaskLaunchContract.compile(attrs)
      refute changed.contract_id == base.contract_id
    end

    assert {:ok, terra} =
             TaskLaunchContract.compile(
               Map.merge(valid_attrs(), %{
                 model: :"gpt-5.6-terra",
                 trigger: :scope_discovery,
                 commissioning_identity: %{kind: "human", authority: "programme"}
               })
             )

    refute terra.contract_id == base.contract_id
    assert {:error, errors} = TaskLaunchContract.compile(Map.merge(valid_attrs(), %{model: :"gpt-5.6-luna", trigger: :scope_discovery}))
    assert :model_trigger_mismatch in errors
  end

  test "rejects ambiguous keys and arbitrary typed values" do
    assert {:error, [:ambiguous_contract_keys]} =
             TaskLaunchContract.compile(Map.put(valid_attrs(), "task", "ambiguous"))

    assert {:error, errors} = TaskLaunchContract.compile(%{valid_attrs() | dependencies: %{}, evidence: 1})
    assert :invalid_dependencies in errors
    assert :invalid_evidence in errors

    assert {:error, [:ambiguous_contract_keys]} = TaskLaunchContract.compile(Map.put(valid_attrs(), self(), "bad"))
    assert {:error, _} = TaskLaunchContract.compile(put_in(valid_attrs(), [:project, :saved_project_id], 42))
    assert {:error, _} = TaskLaunchContract.compile(put_in(valid_attrs(), [:project, :root], {:bad, :root}))
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
      effort: :medium,
      goal_policy: :worker,
      dependencies: [],
      permissions: ["workspace-write"],
      evidence_gates: ["tests"],
      stall_policy: :fail_closed,
      closeout_policy: :reconcile,
      idempotency_identity: "issue-50/implementation/sha",
      conflict_identity: "moonshotbro/sysmiq-symphony:SYS-50:implementation",
      project: %{
        saved_project_id: "b12752f9-9a65-4194-bc49-77808b21d767",
        native_project_id: "01a04aab-c77c-79b0-ab09-65187353bb4b",
        programme: "build-toscanini",
        repository: "moonshotbro/sysmiq-symphony",
        root: "/Users/sysmiq/sysmiq-symphony"
      }
    }
  end

  defp risk_receipt_ref do
    ref = %{
      "schema" => "sysmiq.symphony.risk-receipt.v1",
      "digest" => "pending",
      "repository" => "moonshotbro/sysmiq-symphony",
      "base_sha" => String.duplicate("b", 40),
      "head_sha" => "3d3ee035725b0728f041d8d10fc29f5c8adc42c0",
      "authority_digest" => String.duplicate("c", 64),
      "policy_id" => "sysmiq-risk-policy",
      "policy_version" => "1.0",
      "policy_digest" => String.duplicate("d", 64),
      "compiler_version" => "1.0",
      "matrix_revision" => "matrix-2026-09-02",
      "tier" => 2,
      "required_gate_ids" => ["tests"],
      "unresolved_judgments" => [],
      "escalation_required" => false
    }

    Map.put(ref, "digest", receipt_digest(ref))
  end

  defp runtime_risk_receipt_ref(head_sha) do
    ref = %{risk_receipt_ref() | "head_sha" => head_sha, "required_gate_ids" => ["project-bound-readback"]}
    Map.put(ref, "digest", receipt_digest(ref))
  end

  defp receipt_digest(ref) do
    ref
    |> Map.delete("digest")
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
