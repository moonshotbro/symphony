defmodule SymphonyElixir.Codex.TaskAccountabilityRegistry do
  @moduledoc """
  Deterministic runtime representation of the accepted Library role registry.

  The Library document is authority; this bounded representation is checked in
  with its identity and source revision so runtime policy cannot drift through
  prose, environment, or an unreviewed external read.
  """

  @registry_id "SYS-LIB-ROLE-REGISTRY-001"
  @registry_version "1.0"
  @authority_revision "7cce0ffd5a7ebb6980b6754b996b81fed108023b"
  @canonical_digest "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2"

  @roles ~w(intake_triage investigation_evidence analysis_diagnosis design_specification planning_coordination decision_authorization execution_production engagement_service response_recovery verification_assessment integration_closeout stewardship_curation)
  @aliases %{
    "implementation worker" => "execution_production",
    "production worker" => "execution_production",
    "exact-head reviewer" => "verification_assessment",
    "independent review" => "verification_assessment",
    "independent reviewer" => "verification_assessment",
    "landing owner" => "integration_closeout",
    "landing" => "integration_closeout",
    "recovery owner" => "response_recovery",
    "evidence worker" => "investigation_evidence",
    "programme conductor" => "planning_coordination",
    "goalwriter" => "planning_coordination",
    "task constructor" => "planning_coordination",
    "mozart advisory lead" => "decision_authorization",
    "toscanini orchestration lead" => "planning_coordination",
    "document operations" => "execution_production",
    "customer service" => "engagement_service",
    "incident response" => "response_recovery",
    "monitor" => "verification_assessment",
    "telemetry" => "investigation_evidence",
    "research" => "investigation_evidence",
    "programme" => "planning_coordination",
    "acceptance" => "verification_assessment"
  }

  @canonical_fields %{
    "intake_triage" => %{
      accountable_transition: "classify_and_route",
      completion_predicate: "bounded_work_item_or_explicit_reject",
      accepted_inputs: ["request"],
      permitted_activities: ["classify", "prioritise", "route"],
      outputs: ["typed_intake_or_reject"],
      required_evidence: ["intake_record"],
      protocols: ["handoff_to_authorised_role"],
      liveness_condition: "request_is_resolved_or_routed",
      safety_invariants: ["preserve_request_identity"],
      escalation_stop_rules: ["stop_on_ambiguous_authority"]
    },
    "investigation_evidence" => %{
      accountable_transition: "establish_facts_and_provenance",
      completion_predicate: "evidence_set_is_traceable",
      accepted_inputs: ["bounded_question"],
      permitted_activities: ["inspect", "collect", "compare"],
      outputs: ["traceable_evidence_set"],
      required_evidence: ["sources", "uncertainty"],
      protocols: ["handoff_findings"],
      liveness_condition: "question_is_answered_or_blocked",
      safety_invariants: ["do_not_invent_evidence"],
      escalation_stop_rules: ["stop_on_missing_source"]
    },
    "analysis_diagnosis" => %{
      accountable_transition: "explain_condition_or_options",
      completion_predicate: "diagnosis_or_options_are_evidenced",
      accepted_inputs: ["evidence_set"],
      permitted_activities: ["analyse", "diagnose", "compare_options"],
      outputs: ["evidenced_diagnosis_or_options"],
      required_evidence: ["reasoning_basis", "uncertainty"],
      protocols: ["handoff_analysis"],
      liveness_condition: "interpretation_is_complete_or_escalated",
      safety_invariants: ["separate_fact_from_inference"],
      escalation_stop_rules: ["stop_on_insufficient_evidence"]
    },
    "design_specification" => %{
      accountable_transition: "define_target_state",
      completion_predicate: "specification_meets_constraints",
      accepted_inputs: ["approved_intent"],
      permitted_activities: ["model", "specify", "define_acceptance"],
      outputs: ["actionable_specification"],
      required_evidence: ["constraints", "acceptance_conditions"],
      protocols: ["handoff_to_planning_or_execution"],
      liveness_condition: "target_state_is_actionable",
      safety_invariants: ["preserve_invariants"],
      escalation_stop_rules: ["stop_on_conflicting_requirements"]
    },
    "planning_coordination" => %{
      accountable_transition: "arrange_authorised_work",
      completion_predicate: "plan_is_executable_and_bound",
      accepted_inputs: ["approved_objective"],
      permitted_activities: ["decompose", "sequence", "assign", "coordinate"],
      outputs: ["bound_executable_plan"],
      required_evidence: ["dependencies", "assignments"],
      protocols: ["dispatch_and_reconcile"],
      liveness_condition: "ready_work_is_assigned_or_blocked",
      safety_invariants: ["respect_dependency_and_capacity"],
      escalation_stop_rules: ["stop_on_scope_conflict"]
    },
    "decision_authorization" => %{
      accountable_transition: "make_binding_decision",
      completion_predicate: "decision_is_recorded_with_authority",
      accepted_inputs: ["decision_pack"],
      permitted_activities: ["decide", "approve", "deny", "escalate"],
      outputs: ["authorised_decision_or_escalation"],
      required_evidence: ["authority_basis", "decision_record"],
      protocols: ["judgment_request"],
      liveness_condition: "decision_is_made_or_escalated",
      safety_invariants: ["honour_separation_of_duties"],
      escalation_stop_rules: ["stop_without_delegated_authority"]
    },
    "execution_production" => %{
      accountable_transition: "produce_scoped_change",
      completion_predicate: "change_and_evidence_match_contract",
      accepted_inputs: ["typed_objective"],
      permitted_activities: ["implement", "create", "update"],
      outputs: ["scoped_change"],
      required_evidence: ["change_record", "test_or_quality_evidence"],
      protocols: ["handoff_for_verification"],
      liveness_condition: "change_is_complete_or_blocked",
      safety_invariants: ["respect_write_boundary"],
      escalation_stop_rules: ["stop_on_unexpected_scope"]
    },
    "engagement_service" => %{
      accountable_transition: "resolve_authorised_interaction",
      completion_predicate: "interaction_has_service_outcome",
      accepted_inputs: ["stakeholder_request"],
      permitted_activities: ["respond", "clarify", "commit_within_authority"],
      outputs: ["service_outcome_or_route"],
      required_evidence: ["interaction_record"],
      protocols: ["route_or_follow_up"],
      liveness_condition: "interaction_is_resolved_or_routed",
      safety_invariants: ["protect_sensitive_context"],
      escalation_stop_rules: ["stop_on_missing_authority"]
    },
    "response_recovery" => %{
      accountable_transition: "restore_acceptable_state",
      completion_predicate: "service_or_work_state_restored",
      accepted_inputs: ["failure_signal"],
      permitted_activities: ["contain", "mitigate", "restore"],
      outputs: ["restored_state_or_escalation"],
      required_evidence: ["incident_timeline", "recovery_record"],
      protocols: ["escalate_and_handoff"],
      liveness_condition: "disruption_is_contained_or_escalated",
      safety_invariants: ["preserve_forensics"],
      escalation_stop_rules: ["stop_on_unsafe_recovery"]
    },
    "verification_assessment" => %{
      accountable_transition: "assess_acceptance_condition",
      completion_predicate: "verdict_is_reproducible",
      accepted_inputs: ["candidate_result"],
      permitted_activities: ["inspect", "test", "assess"],
      outputs: ["assessment_verdict"],
      required_evidence: ["verdict", "reproduction_basis"],
      protocols: ["return_verdict_to_closeout"],
      liveness_condition: "verdict_is_issued_or_blocked",
      safety_invariants: ["independence_from_execution"],
      escalation_stop_rules: ["stop_on_unverifiable_result"]
    },
    "integration_closeout" => %{
      accountable_transition: "reconcile_and_close_destination",
      completion_predicate: "accepted_result_is_integrated_with_receipt",
      accepted_inputs: ["accepted_result"],
      permitted_activities: ["reconcile", "land", "close"],
      outputs: ["integrated_result_and_receipt"],
      required_evidence: ["destination_receipt", "clean_state"],
      protocols: ["closeout_and_archive"],
      liveness_condition: "destination_is_reconciled_or_blocked",
      safety_invariants: ["honour_exact_head"],
      escalation_stop_rules: ["stop_on_destination_conflict"]
    },
    "stewardship_curation" => %{
      accountable_transition: "maintain_trusted_knowledge_or_record",
      completion_predicate: "curated_state_is_findable_and_provenanced",
      accepted_inputs: ["record_set"],
      permitted_activities: ["classify", "curate", "retire", "link_provenance"],
      outputs: ["curated_provenanced_state"],
      required_evidence: ["provenance", "lifecycle_state"],
      protocols: ["publish_or_retire"],
      liveness_condition: "collection_is_current_or_exception_recorded",
      safety_invariants: ["preserve_traceability"],
      escalation_stop_rules: ["stop_on_conflicting_authority"]
    }
  }

  @profiles %{
    "execution_production" => %{
      permissions: ["write_bound_scope"],
      prohibited: ["approve_own_work", "land_without_authority"],
      independence: ["must_not_self_approve"],
      closeout: "production",
      required_evidence: ["change_record", "test_or_quality_evidence"]
    },
    "verification_assessment" => %{
      permissions: ["read_candidate_and_test_scope"],
      prohibited: ["modify_candidate", "approve_own_execution"],
      independence: ["separate_attempt_or_principal"],
      closeout: "verification",
      required_evidence: ["verdict", "reproduction_basis"]
    },
    "integration_closeout" => %{
      permissions: ["land_bound_destination"],
      prohibited: ["bypass_verification", "alter_accepted_result"],
      independence: ["distinct_from_execution_and_verification"],
      closeout: "integration",
      required_evidence: ["accepted_verdict", "destination_receipt", "clean_state"]
    },
    "investigation_evidence" => %{permissions: ["read_scoped_sources"], prohibited: ["bind_final_decision"], independence: [], closeout: "evidence"},
    "analysis_diagnosis" => %{permissions: ["read_scoped_inputs"], prohibited: ["authorise_outcome"], independence: [], closeout: "analysis"},
    "design_specification" => %{permissions: ["write_scoped_specification"], prohibited: ["implement_unapproved_change"], independence: [], closeout: "design"},
    "planning_coordination" => %{permissions: ["create_scoped_tasks"], prohibited: ["grant_unbounded_authority"], independence: [], closeout: "coordination"},
    "decision_authorization" => %{permissions: ["bind_delegated_decision"], prohibited: ["exceed_delegation"], independence: ["may_be_human_held"], closeout: "authorization"},
    "intake_triage" => %{permissions: ["create_work_item"], prohibited: ["execute_scoped_change"], independence: [], closeout: "intake"},
    "engagement_service" => %{permissions: ["communicate_scoped_response"], prohibited: ["promise_unauthorised_change"], independence: [], closeout: "service"},
    "response_recovery" => %{
      permissions: ["write_recovery_scope"],
      prohibited: ["erase_evidence", "redefine_acceptance"],
      independence: [],
      closeout: "recovery",
      required_evidence: ["incident_timeline", "recovery_record"]
    },
    "stewardship_curation" => %{permissions: ["write_curated_scope"], prohibited: ["silently_change_authority"], independence: [], closeout: "stewardship"}
  }

  @spec identity() :: %{
          registry_id: String.t(),
          registry_version: String.t(),
          authority_revision: String.t(),
          canonical_digest: String.t()
        }
  def identity do
    %{
      registry_id: @registry_id,
      registry_version: @registry_version,
      authority_revision: @authority_revision,
      canonical_digest: @canonical_digest
    }
  end

  @spec roles() :: [String.t()]
  def roles, do: @roles

  @spec profiles() :: map()
  def profiles, do: @profiles |> Map.merge(@canonical_fields, fn _key, policy, canonical -> Map.merge(policy, canonical) end)

  @spec compile(map()) :: {:ok, map()} | {:error, atom() | {atom(), term()}}
  def compile(attrs) when is_map(attrs) do
    version = Map.get(attrs, :registry_version, Map.get(attrs, "registry_version", @registry_version))
    role_input = Map.get(attrs, :primary_role, Map.get(attrs, "primary_role", "execution_production"))
    alias_input = Map.get(attrs, :domain_alias, Map.get(attrs, "domain_alias"))
    permissions = Map.get(attrs, :permission_envelope, Map.get(attrs, "permission_envelope", []))
    evidence = Map.get(attrs, :evidence, Map.get(attrs, "evidence", []))

    enforced =
      Map.has_key?(attrs, :primary_role) or Map.has_key?(attrs, "primary_role") or
        Map.has_key?(attrs, :registry_version) or Map.has_key?(attrs, "registry_version")

    with :ok <- version_guard(version),
         {:ok, role} <- resolve_role(role_input, alias_input),
         {:ok, profile} <- Map.fetch(@profiles, role),
         :ok <- authority_guard(attrs, enforced),
         :ok <- permission_guard(permissions, profile.permissions),
         :ok <- evidence_guard(evidence, Map.merge(profile, Map.fetch!(@canonical_fields, role)), enforced),
         :ok <- handoff_guard(attrs, role, profile) do
      profile = Map.merge(profile, Map.fetch!(@canonical_fields, role))

      {:ok,
       Map.merge(
         identity(),
         Map.merge(profile, %{
           canonical_digest: @canonical_digest,
           primary_role: role,
           domain_alias: alias_input || role,
           work_character: work_character(attrs),
           permission_envelope: permissions,
           prohibited_actions: profile.prohibited,
           independence_rules: profile.independence,
           closeout_class: profile.closeout
         })
       )}
    end
  end

  def compile(_), do: {:error, :registry_input_not_a_map}

  @spec compile_domain_pack(map()) :: {:ok, map()} | {:error, term()}
  def compile_domain_pack(%{domain: domain, alias: alias_name, primary_role: role} = pack)
      when is_binary(domain) and is_binary(alias_name) do
    compile(Map.merge(pack, %{domain_alias: alias_name, primary_role: role}))
  end

  def compile_domain_pack(_), do: {:error, :invalid_domain_pack}

  defp version_guard(@registry_version), do: :ok
  defp version_guard(version), do: {:error, {:unknown_registry_version, version}}

  defp authority_guard(_attrs, false), do: :ok

  defp authority_guard(attrs, true) do
    expected = %{
      "registry_id" => @registry_id,
      "registry_version" => @registry_version,
      "authority_revision" => @authority_revision,
      "canonical_digest" => @canonical_digest
    }

    if Enum.all?(expected, fn {key, value} -> Map.get(attrs, key, Map.get(attrs, String.to_existing_atom(key))) == value end),
      do: :ok,
      else: {:error, :invalid_registry_authority}
  end

  defp resolve_role(role, alias_name) do
    role = normalize_role(role)

    role =
      %{
        "implementation" => "execution_production",
        "independent_review" => "verification_assessment",
        "landing" => "integration_closeout",
        "recovery" => "response_recovery",
        "monitor" => "verification_assessment",
        "telemetry" => "investigation_evidence",
        "research" => "investigation_evidence",
        "programme" => "planning_coordination",
        "acceptance" => "verification_assessment"
      }
      |> Map.get(role, role)

    alias_role = if alias_name, do: Map.get(@aliases, normalize(alias_name)), else: nil

    cond do
      role not in @roles -> {:error, {:unknown_registry_role, role}}
      alias_name && is_nil(alias_role) -> {:error, {:unknown_domain_alias, normalize(alias_name)}}
      alias_role && alias_role != role -> {:error, :domain_alias_role_mismatch}
      true -> {:ok, role}
    end
  end

  defp permission_guard(requested, allowed) when is_list(requested) do
    if Enum.all?(requested, &(&1 in allowed)), do: :ok, else: {:error, :permission_widening}
  end

  defp permission_guard(_, _), do: {:error, :invalid_permission_envelope}

  defp evidence_guard(_evidence, _profile, false), do: :ok

  defp evidence_guard(evidence, profile, true) when is_list(evidence) do
    if Enum.all?(profile.required_evidence, &(&1 in evidence)), do: :ok, else: {:error, :missing_required_evidence}
  end

  defp evidence_guard(_, _, _), do: {:error, :missing_required_evidence}

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp handoff_guard(attrs, role, profile) do
    prohibited = Map.get(attrs, :prohibited_actions, Map.get(attrs, "prohibited_actions", []))
    handoff = Map.get(attrs, :handoff, Map.get(attrs, "handoff"))

    cond do
      not is_list(prohibited) or Enum.any?(prohibited, &(&1 in profile.prohibited)) -> {:error, :prohibited_action}
      role == "execution_production" and handoff in ["approve", "land", "self_review"] -> {:error, :prohibited_handoff}
      role == "verification_assessment" and not valid_independent_review?(attrs) -> {:error, :independence_violation}
      role == "integration_closeout" and not valid_integration_closeout?(attrs) -> {:error, :missing_accepted_verdict}
      profile.independence != [] and Map.get(attrs, :prior_role, Map.get(attrs, "prior_role")) == role -> {:error, :independence_violation}
      true -> :ok
    end
  end

  defp valid_independent_review?(attrs) do
    execution = identity_value(attrs, :execution_principal)
    reviewer = identity_value(attrs, :reviewer_principal)
    handoff = identity_value(attrs, :handoff)
    same_candidate?(attrs) and handoff == "independent_review" and nonblank(execution) and nonblank(reviewer) and execution != reviewer
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_integration_closeout?(attrs) do
    verdict = identity_value(attrs, :accepted_verdict)
    integrator = identity_value(attrs, :integrator_principal)
    execution = identity_value(attrs, :execution_principal)
    reviewer = identity_value(attrs, :reviewer_principal)

    accepted? = is_map(verdict) and verdict["accepted"] == true
    review_role? = is_map(verdict) and verdict["role"] in ["verification_assessment", "independent_review"]

    receipt? =
      nonblank(identity_value(attrs, :receipt_identity)) and
        identity_value(attrs, :receipt_fence) == identity_value(attrs, :verdict_fence)

    verdict_fence? = is_map(verdict) and verdict["fence"] == identity_value(attrs, :verdict_fence)

    same_candidate?(attrs) and verdict_fence? and accepted? and review_role? and receipt? and nonblank(integrator) and
      integrator not in [execution, reviewer]
  end

  defp same_candidate?(attrs) do
    fields = [:candidate_id, :attempt, :fence, :exact_revision, :verdict_fence]

    Enum.all?(fields, &nonblank(identity_value(attrs, &1))) and
      identity_value(attrs, :verdict_candidate_id) == identity_value(attrs, :candidate_id) and
      identity_value(attrs, :verdict_attempt) == identity_value(attrs, :attempt) and
      identity_value(attrs, :verdict_exact_revision) == identity_value(attrs, :exact_revision) and
      nonblank(identity_value(attrs, :verdict_fence))
  end

  defp identity_value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  defp nonblank(value) when is_integer(value), do: value >= 0
  defp nonblank(value), do: is_binary(value) and String.trim(value) != ""

  defp work_character(attrs), do: Map.get(attrs, :work_character, Map.get(attrs, "work_character", "bounded"))
  defp normalize_role(value), do: normalize(value) |> String.replace(" ", "_")
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_), do: ""
end
