defmodule SymphonyElixir.Codex.TaskAccountabilityRegistryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.TaskAccountabilityRegistry

  @evidence ["change_record", "test_or_quality_evidence"]

  test "compiles the canonical production role and software alias" do
    assert {:ok, compiled} =
             TaskAccountabilityRegistry.compile(%{
               registry_id: "SYS-LIB-ROLE-REGISTRY-001",
               registry_version: "1.0",
               canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2",
               primary_role: "execution_production",
               domain_alias: "implementation worker",
               authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
               work_character: "bounded",
               permission_envelope: ["write_bound_scope"],
               evidence: @evidence
             })

    assert compiled.primary_role == "execution_production"
    assert compiled.registry_id == "SYS-LIB-ROLE-REGISTRY-001"
    assert compiled.authority_revision == "7cce0ffd5a7ebb6980b6754b996b81fed108023b"
  end

  test "compiles a non-software domain pack without changing the role machine" do
    assert {:ok, compiled} =
             TaskAccountabilityRegistry.compile_domain_pack(%{
               domain: "document operations",
               alias: "document operations",
               primary_role: "execution_production",
               registry_id: "SYS-LIB-ROLE-REGISTRY-001",
               registry_version: "1.0",
               authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
               canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2",
               permission_envelope: ["write_bound_scope"],
               evidence: @evidence
             })

    assert compiled.primary_role == "execution_production"
    assert compiled.domain_alias == "document operations"
  end

  test "fails closed for unknown version, widened permissions, missing evidence, and unsafe handoff" do
    base = %{
      registry_id: "SYS-LIB-ROLE-REGISTRY-001",
      registry_version: "1.0",
      authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
      canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2",
      primary_role: "execution_production",
      permission_envelope: ["write_bound_scope"],
      evidence: @evidence
    }

    assert {:error, {:unknown_registry_version, "9.0"}} =
             TaskAccountabilityRegistry.compile(%{base | registry_version: "9.0"})

    assert {:error, :permission_widening} =
             TaskAccountabilityRegistry.compile(%{base | permission_envelope: ["write_bound_scope", "land_bound_destination"]})

    assert {:error, :missing_required_evidence} = TaskAccountabilityRegistry.compile(%{base | evidence: []})
    assert {:error, :prohibited_handoff} = TaskAccountabilityRegistry.compile(Map.put(base, :handoff, "land"))
  end

  test "fails closed for unknown roles and reviewer self-review" do
    base = %{
      registry_id: "SYS-LIB-ROLE-REGISTRY-001",
      registry_version: "1.0",
      authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
      canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2",
      primary_role: "verification_assessment",
      permission_envelope: ["read_candidate_and_test_scope"],
      evidence: ["verdict", "reproduction_basis"]
    }

    assert {:error, {:unknown_registry_role, "mystery"}} = TaskAccountabilityRegistry.compile(%{base | primary_role: "mystery"})
    assert {:error, :independence_violation} = TaskAccountabilityRegistry.compile(Map.put(base, :prior_role, "verification_assessment"))
  end

  test "rejects malformed packs, aliases, permissions, and prohibited actions" do
    assert {:error, :invalid_domain_pack} = TaskAccountabilityRegistry.compile_domain_pack(%{})

    base = %{
      registry_id: "SYS-LIB-ROLE-REGISTRY-001",
      registry_version: "1.0",
      authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
      canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2",
      primary_role: "execution_production",
      permission_envelope: ["write_bound_scope"],
      evidence: @evidence
    }

    assert {:error, {:unknown_domain_alias, "unknown alias"}} = TaskAccountabilityRegistry.compile(Map.put(base, :domain_alias, "unknown alias"))
    assert {:error, :domain_alias_role_mismatch} = TaskAccountabilityRegistry.compile(Map.put(base, :domain_alias, "exact-head reviewer"))

    assert {:error, :invalid_permission_envelope} =
             TaskAccountabilityRegistry.compile(%{base | permission_envelope: :write_bound_scope})

    assert {:error, :prohibited_action} = TaskAccountabilityRegistry.compile(Map.put(base, :prohibited_actions, ["approve_own_work"]))
    assert {:error, :prohibited_action} = TaskAccountabilityRegistry.compile(Map.put(base, :prohibited_actions, :approve_own_work))
  end

  test "binds independent review and landing to one candidate without self-review" do
    revision = String.duplicate("a", 40)

    review = %{
      registry_id: "SYS-LIB-ROLE-REGISTRY-001",
      registry_version: "1.0",
      authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
      canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2",
      primary_role: "verification_assessment",
      domain_alias: "independent review",
      permission_envelope: ["read_candidate_and_test_scope"],
      evidence: ["verdict", "reproduction_basis"],
      handoff: "independent_review",
      execution_principal: "worker",
      reviewer_principal: "reviewer",
      candidate_id: "candidate-1",
      verdict_candidate_id: "candidate-1",
      attempt: 0,
      verdict_attempt: 0,
      fence: "fence-1",
      exact_revision: revision,
      verdict_exact_revision: revision,
      verdict_fence: "verdict-fence-1"
    }

    assert {:ok, compiled} = TaskAccountabilityRegistry.compile(review)
    assert compiled.primary_role == "verification_assessment"
    assert {:error, :independence_violation} = TaskAccountabilityRegistry.compile(Map.put(review, :reviewer_principal, "worker"))

    landing =
      Map.merge(review, %{
        primary_role: "integration_closeout",
        domain_alias: "landing owner",
        permission_envelope: ["land_bound_destination"],
        evidence: ["accepted_verdict", "destination_receipt", "clean_state"],
        integrator_principal: "integrator",
        accepted_verdict: %{"accepted" => true, "role" => "verification_assessment", "fence" => "verdict-fence-1"},
        receipt_identity: "receipt-1",
        receipt_fence: "verdict-fence-1"
      })

    assert {:ok, _} = TaskAccountabilityRegistry.compile(landing)
    assert {:error, :missing_accepted_verdict} = TaskAccountabilityRegistry.compile(Map.delete(landing, :accepted_verdict))
    assert {:error, :missing_accepted_verdict} = TaskAccountabilityRegistry.compile(Map.put(landing, :verdict_attempt, 1))
    assert {:error, :missing_accepted_verdict} = TaskAccountabilityRegistry.compile(Map.put(landing, :verdict_fence, "replayed-fence"))
    assert {:error, :missing_accepted_verdict} = TaskAccountabilityRegistry.compile(Map.put(landing, :integrator_principal, "worker"))
  end

  test "requires exact authority identity and role-specific evidence" do
    base = %{
      registry_id: "SYS-LIB-ROLE-REGISTRY-001",
      registry_version: "1.0",
      authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
      canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2",
      primary_role: "response_recovery",
      permission_envelope: ["write_recovery_scope"],
      evidence: ["incident_timeline", "recovery_record"]
    }

    assert {:ok, compiled} = TaskAccountabilityRegistry.compile(base)
    assert compiled.required_evidence == ["incident_timeline", "recovery_record"]
    assert {:error, :missing_required_evidence} = TaskAccountabilityRegistry.compile(%{base | evidence: []})
    assert {:error, :invalid_registry_authority} = TaskAccountabilityRegistry.compile(%{base | canonical_digest: "bad"})
    assert {:error, :invalid_registry_authority} = TaskAccountabilityRegistry.compile(Map.delete(base, :registry_id))
  end

  test "maps every legacy runtime role explicitly and preserves canonical profile fields" do
    authority = %{
      registry_id: "SYS-LIB-ROLE-REGISTRY-001",
      registry_version: "1.0",
      authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
      canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2"
    }

    for {legacy, alias_name, canonical, evidence} <- [
          {"recovery", "recovery owner", "response_recovery", ["incident_timeline", "recovery_record"]},
          {"monitor", "monitor", "verification_assessment", ["verdict", "reproduction_basis"]},
          {"telemetry", "telemetry", "investigation_evidence", ["sources", "uncertainty"]}
        ] do
      identity =
        if canonical == "verification_assessment" do
          %{
            handoff: "independent_review",
            execution_principal: "worker",
            reviewer_principal: "reviewer",
            candidate_id: "candidate",
            verdict_candidate_id: "candidate",
            attempt: 0,
            verdict_attempt: 0,
            fence: "fence",
            exact_revision: String.duplicate("a", 40),
            verdict_exact_revision: String.duplicate("a", 40),
            verdict_fence: "verdict-fence"
          }
        else
          %{}
        end

      assert {:ok, compiled} =
               TaskAccountabilityRegistry.compile(
                 Map.merge(
                   authority,
                   Map.merge(identity, %{primary_role: legacy, domain_alias: alias_name, permission_envelope: TaskAccountabilityRegistry.profiles()[canonical].permissions, evidence: evidence})
                 )
               )

      assert compiled.primary_role == canonical
      assert is_binary(compiled.completion_predicate)
      assert is_list(compiled.protocols)
      assert is_list(compiled.safety_invariants)
      assert is_list(compiled.escalation_stop_rules)
    end

    assert TaskAccountabilityRegistry.profiles()["investigation_evidence"].required_evidence == ["sources", "uncertainty"]
  end
end
