defmodule SymphonyElixir.Codex.TaskLaunchContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.TaskLaunchContract

  defp risk_assurance(overrides \\ %{}) do
    Map.merge(
      %{
        schema: "sysmiq.symphony.risk-assurance.v1",
        repository: "moonshotbro/sysmiq-symphony",
        head_sha: "3d3ee035725b0728f041d8d10fc29f5c8adc42c0",
        risk_receipt_digest: String.duplicate("a", 64),
        assurance_receipt_digest: String.duplicate("b", 64),
        evidence_manifest_digest: String.duplicate("c", 64),
        matrix_revision: "risk-matrix-v1",
        required_gate_ids: ["G-EXACT-HEAD-REVIEW"],
        artifact_url: "https://github.com/moonshotbro/sysmiq-symphony/actions/runs/50/artifacts",
        stage: "review",
        assurance_outcome: "unresolved"
      },
      overrides
    )
  end

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

      assert {:ok, contract} =
               TaskLaunchContract.from_runtime(issue, root,
                 trigger: :integration_design,
                 commissioning_identity: %{kind: "human", authority: "programme"}
               )

      assert contract.executing_identity.model == :"gpt-5.6-terra"
      assert contract.project.saved_project_id != contract.project.native_project_id
      assert TaskLaunchContract.prompt(contract, "work") =~ contract.contract_id
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

  test "workspace verification rejects a prepared contract after the exact head changes" do
    root = Path.join(System.tmp_dir!(), "symphony-contract-head-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["init", "-q", root])
    {_, 0} = System.cmd("git", ["-C", root, "config", "user.email", "test@example.test"])
    {_, 0} = System.cmd("git", ["-C", root, "config", "user.name", "Test"])
    {_, 0} = System.cmd("git", ["-C", root, "remote", "add", "origin", "https://github.com/moonshotbro/sysmiq-symphony.git"])
    File.write!(Path.join(root, "README.md"), "one\n")
    {_, 0} = System.cmd("git", ["-C", root, "add", "."])
    {_, 0} = System.cmd("git", ["-C", root, "commit", "-qm", "one"])

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

      issue = %SymphonyElixir.Tracker.Issue{identifier: "SYS-52", title: "Prepared worker"}
      assert {:ok, contract} = TaskLaunchContract.from_runtime(issue, root)
      assert :ok = TaskLaunchContract.verify_workspace(contract, root)

      File.write!(Path.join(root, "README.md"), "two\n")
      {_, 0} = System.cmd("git", ["-C", root, "add", "."])
      {_, 0} = System.cmd("git", ["-C", root, "commit", "-qm", "two"])
      assert {:error, :workspace_contract_mismatch} = TaskLaunchContract.verify_workspace(contract, root)
    after
      File.rm_rf(root)
    end
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

  test "enforces role and goal policy boundaries" do
    assert {:error, errors} = TaskLaunchContract.compile(%{valid_attrs() | role: :landing, goal_policy: :worker})
    assert :role_requires_no_goal in errors

    assert {:error, errors} = TaskLaunchContract.compile(%{valid_attrs() | model: "unsupported"})
    assert {:unsupported_model, nil} in errors
  end

  test "requires closed risk assurance for review and landing contracts" do
    review = review_attrs()
    assert {:ok, contract} = TaskLaunchContract.compile(Map.put(review, :risk_assurance, risk_assurance()))
    assert contract.risk_assurance["head_sha"] == contract.exact_revision

    assert {:ok, changed} =
             TaskLaunchContract.compile(Map.put(review, :risk_assurance, risk_assurance(%{risk_receipt_digest: String.duplicate("d", 64)})))

    refute changed.contract_id == contract.contract_id

    assert {:error, errors} = TaskLaunchContract.compile(review)
    assert :invalid_risk_assurance in errors

    landing =
      Map.merge(review, %{
        role: :landing,
        write_boundary: :merge,
        evidence: ["accepted_verdict", "destination_receipt", "clean_state"],
        permissions: ["land_bound_destination"],
        primary_role: "integration_closeout",
        domain_alias: "landing owner",
        permission_envelope: ["land_bound_destination"],
        integrator_principal: "integrator",
        accepted_verdict: %{"accepted" => true, "role" => "verification_assessment", "fence" => "lease-50-1"},
        receipt_identity: "receipt-50",
        receipt_fence: "lease-50-1"
      })

    assert {:ok, _} = TaskLaunchContract.compile(Map.put(landing, :risk_assurance, risk_assurance(%{stage: "landing", assurance_outcome: "pass"})))
    assert {:error, errors} = TaskLaunchContract.compile(landing)
    assert :invalid_risk_assurance in errors

    assert {:error, errors} =
             TaskLaunchContract.compile(Map.put(review, :risk_assurance, risk_assurance(%{repository: "other/repository"})))

    assert :invalid_risk_assurance in errors
    assert {:error, errors} = TaskLaunchContract.compile(Map.put(review, :risk_assurance, Map.put(risk_assurance(), :extra, "rejected")))
    assert :invalid_risk_assurance in errors

    assert {:error, errors} =
             TaskLaunchContract.compile(Map.put(review, :risk_assurance, %{:schema => risk_assurance().schema, "schema" => risk_assurance().schema}))

    assert :invalid_risk_assurance in errors
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

  defp review_attrs do
    Map.merge(valid_attrs(), %{
      role: :independent_review,
      goal_policy: :none,
      write_boundary: :review,
      evidence: ["verdict", "reproduction_basis"],
      permissions: ["read_candidate_and_test_scope"],
      primary_role: "verification_assessment",
      domain_alias: "independent review",
      registry_id: "SYS-LIB-ROLE-REGISTRY-001",
      registry_version: "1.0",
      authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
      canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2",
      permission_envelope: ["read_candidate_and_test_scope"],
      handoff: "independent_review",
      execution_principal: "worker",
      reviewer_principal: "reviewer",
      candidate_id: "candidate-50",
      verdict_candidate_id: "candidate-50",
      verdict_attempt: 0,
      execution_fence: "lease-50-1",
      verdict_exact_revision: "3d3ee035725b0728f041d8d10fc29f5c8adc42c0",
      verdict_fence: "lease-50-1"
    })
  end
end
