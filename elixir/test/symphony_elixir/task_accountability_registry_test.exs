defmodule SymphonyElixir.Codex.TaskAccountabilityRegistryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.TaskAccountabilityRegistry

  @evidence ["change_record", "test_or_quality_evidence"]

  test "compiles the canonical production role and software alias" do
    assert {:ok, compiled} =
             TaskAccountabilityRegistry.compile(%{
               registry_version: "1.0",
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
               permission_envelope: ["write_bound_scope"],
               evidence: @evidence
             })

    assert compiled.primary_role == "execution_production"
    assert compiled.domain_alias == "document operations"
  end

  test "fails closed for unknown version, widened permissions, missing evidence, and unsafe handoff" do
    base = %{registry_version: "1.0", primary_role: "execution_production", permission_envelope: ["write_bound_scope"], evidence: @evidence}

    assert {:error, {:unknown_registry_version, "9.0"}} =
             TaskAccountabilityRegistry.compile(%{base | registry_version: "9.0"})

    assert {:error, :permission_widening} =
             TaskAccountabilityRegistry.compile(%{base | permission_envelope: ["write_bound_scope", "land_bound_destination"]})

    assert {:error, :missing_required_evidence} = TaskAccountabilityRegistry.compile(%{base | evidence: []})
    assert {:error, :prohibited_handoff} = TaskAccountabilityRegistry.compile(Map.put(base, :handoff, "land"))
  end

  test "fails closed for unknown roles and reviewer self-review" do
    base = %{registry_version: "1.0", primary_role: "verification_assessment", permission_envelope: ["read_candidate_and_test_scope"], evidence: []}
    assert {:error, {:unknown_registry_role, "mystery"}} = TaskAccountabilityRegistry.compile(%{base | primary_role: "mystery"})
    assert {:error, :independence_violation} = TaskAccountabilityRegistry.compile(Map.put(base, :prior_role, "verification_assessment"))
  end

  test "rejects malformed packs, aliases, permissions, and prohibited actions" do
    assert {:error, :invalid_domain_pack} = TaskAccountabilityRegistry.compile_domain_pack(%{})

    base = %{registry_version: "1.0", primary_role: "execution_production", permission_envelope: ["write_bound_scope"], evidence: @evidence}
    assert {:error, {:unknown_domain_alias, "unknown alias"}} = TaskAccountabilityRegistry.compile(Map.put(base, :domain_alias, "unknown alias"))
    assert {:error, :domain_alias_role_mismatch} = TaskAccountabilityRegistry.compile(Map.put(base, :domain_alias, "exact-head reviewer"))

    assert {:error, :invalid_permission_envelope} =
             TaskAccountabilityRegistry.compile(%{base | permission_envelope: :write_bound_scope})

    assert {:error, :prohibited_action} = TaskAccountabilityRegistry.compile(Map.put(base, :prohibited_actions, ["approve_own_work"]))
    assert {:error, :prohibited_action} = TaskAccountabilityRegistry.compile(Map.put(base, :prohibited_actions, :approve_own_work))
  end
end
