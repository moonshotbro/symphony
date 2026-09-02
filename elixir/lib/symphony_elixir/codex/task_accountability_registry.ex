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

  @profile_defaults %{
    completion_predicate: "transition_is_complete_and_evidenced",
    accepted_inputs: ["bounded_task_contract"],
    permitted_activities: ["perform_role_methods"],
    required_evidence: ["provenance", "completion_record"],
    outputs: ["role_result"],
    protocols: ["handoff_to_next_authorised_transition"],
    liveness_condition: "progress_is_observable_or_escalated",
    safety_invariants: ["respect_contract_and_scope"],
    escalation_stop_rules: ["stop_on_missing_authority_or_evidence"]
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

  @spec identity() :: %{registry_id: String.t(), registry_version: String.t(), authority_revision: String.t()}
  def identity, do: %{registry_id: @registry_id, registry_version: @registry_version, authority_revision: @authority_revision}

  @spec roles() :: [String.t()]
  def roles, do: @roles

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
         :ok <- evidence_guard(evidence, Map.merge(@profile_defaults, profile), enforced),
         :ok <- handoff_guard(attrs, role, profile) do
      profile = Map.merge(@profile_defaults, profile)

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

  defp valid_integration_closeout?(attrs) do
    verdict = identity_value(attrs, :accepted_verdict)
    integrator = identity_value(attrs, :integrator_principal)
    execution = identity_value(attrs, :execution_principal)
    reviewer = identity_value(attrs, :reviewer_principal)

    accepted? = is_map(verdict) and verdict["accepted"] == true
    review_role? = is_map(verdict) and verdict["role"] in ["verification_assessment", "independent_review"]
    receipt? = nonblank(identity_value(attrs, :receipt_identity))

    same_candidate?(attrs) and accepted? and review_role? and receipt? and nonblank(integrator) and
      integrator not in [execution, reviewer]
  end

  defp same_candidate?(attrs) do
    fields = [:candidate_id, :attempt, :fence, :exact_revision]

    Enum.all?(fields, &nonblank(identity_value(attrs, &1))) and
      identity_value(attrs, :verdict_candidate_id) == identity_value(attrs, :candidate_id) and
      identity_value(attrs, :verdict_attempt) == identity_value(attrs, :attempt) and
      identity_value(attrs, :verdict_exact_revision) == identity_value(attrs, :exact_revision)
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
