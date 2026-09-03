# credo:disable-for-this-file Credo.Check.Warning.StructFieldAmount
defmodule SymphonyElixir.Codex.TaskLaunchContract do
  @moduledoc """
  Pure compiler for the bounded identity carried by a Codex task launch.

  This module deliberately does not create or inspect App Server tasks.  It
  validates the authority boundary before a caller enters that effectful path.
  """

  alias SymphonyElixir.Codex.TaskAccountabilityRegistry
  alias SymphonyElixir.Config

  @roles [
    :programme,
    :implementation,
    :independent_review,
    :landing,
    :recovery,
    :research,
    :monitor,
    :telemetry,
    :acceptance
  ]
  @models ~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna)a
  @model_providers ~w(sysmiq-azure-foundry)a
  @model_deployments %{
    "gpt-5.6-sol": "gpt",
    "gpt-5.6-terra": "gpt-terra",
    "gpt-5.6-luna": "gpt-luna"
  }
  @goal_policies ~w(none worker programme)a
  @worker_goal_roles ~w(implementation recovery research)a
  @write_domains ~w(none product review merge recovery evidence programme)a
  @efforts ~w(low medium high xhigh max ultra)a
  @stall_policies ~w(fail_closed bounded)a
  @closeout_policies ~w(reconcile archive_none archive_exact)a
  @luna_triggers ~w(bounded implementation tests documentation hygiene mechanical_review gate_repair)a
  @terra_triggers ~w(ambiguous_diagnosis integration_design repository_wide_judgment recovery privacy_telemetry_semantics provider_boundary_reasoning scope_discovery)a
  @sol_triggers ~w(security_architecture consequential_production_customer_billing difficult_cross_repository_incident final_high_risk_review)a

  @type role ::
          :programme
          | :implementation
          | :independent_review
          | :landing
          | :recovery
          | :research
          | :monitor
          | :telemetry
          | :acceptance
  @type goal_policy :: :none | :worker | :programme
  @type saved_project_binding :: %{
          saved_project_id: String.t(),
          native_project_id: String.t(),
          repository: String.t(),
          root: Path.t(),
          programme: String.t()
        }
  @type executing_identity :: %{
          contract_id: String.t(),
          task: String.t(),
          title: String.t(),
          model: atom(),
          model_provider: :"sysmiq-azure-foundry",
          model_deployment: String.t(),
          provider_allocation_digest: String.t(),
          effort: atom(),
          role: role(),
          issue_or_pr: String.t(),
          exact_revision: String.t(),
          risk_assurance: map() | nil,
          attempt: non_neg_integer(),
          fence: String.t(),
          project: saved_project_binding(),
          registry_id: String.t(),
          registry_version: String.t(),
          primary_role: String.t(),
          domain_alias: String.t(),
          authority_revision: String.t(),
          work_character: String.t(),
          permission_envelope: [String.t()]
        }
  @type commissioning_identity ::
          %{kind: :human, authority: String.t()}
          | %{
              kind: :agent,
              contract_id: String.t(),
              task_id: String.t(),
              role: role(),
              model: atom(),
              effort: atom()
            }
  @type escalation_link ::
          %{
            prior_contract_id: String.t(),
            prior_task_id: String.t(),
            prior_role: role(),
            prior_model: atom(),
            prior_effort: atom(),
            trigger: atom(),
            reason: String.t()
          }
  @type t :: %__MODULE__{
          contract_id: String.t(),
          programme: String.t(),
          repository: String.t(),
          issue_or_pr: String.t(),
          role: role(),
          task: String.t(),
          attempt: non_neg_integer(),
          fence: String.t(),
          exact_revision: String.t(),
          risk_assurance: map() | nil,
          write_boundary: atom(),
          evidence: [String.t()],
          model_provider: :"sysmiq-azure-foundry",
          model_deployment: String.t(),
          provider_allocation_digest: String.t(),
          effort: atom(),
          trigger: atom(),
          goal_policy: goal_policy(),
          dependencies: [String.t()],
          permissions: [String.t()],
          evidence_gates: [String.t()],
          stall_policy: atom(),
          closeout_policy: atom(),
          idempotency_identity: String.t(),
          conflict_identity: String.t(),
          commissioning_identity: commissioning_identity() | nil,
          executing_identity: executing_identity(),
          escalation: escalation_link() | nil,
          supersedes: %{contract_id: String.t(), resolution: String.t()} | nil,
          title: String.t(),
          project: saved_project_binding(),
          accountability: map()
        }

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :contract_id,
    :programme,
    :repository,
    :issue_or_pr,
    :role,
    :task,
    :attempt,
    :fence,
    :exact_revision,
    :risk_assurance,
    :write_boundary,
    :evidence,
    :model_provider,
    :model_deployment,
    :provider_allocation_digest,
    :effort,
    :trigger,
    :goal_policy,
    :title,
    :dependencies,
    :permissions,
    :evidence_gates,
    :stall_policy,
    :closeout_policy,
    :idempotency_identity,
    :conflict_identity,
    :commissioning_identity,
    :executing_identity,
    :escalation,
    :supersedes,
    :project,
    :accountability
  ]

  @spec supported_roles() :: [role()]
  def supported_roles, do: @roles

  @spec supported_models() :: [atom()]
  def supported_models, do: @models

  @spec deployment_for_model(atom()) :: String.t() | nil
  def deployment_for_model(model), do: Map.get(@model_deployments, model)

  @spec supported_deployments() :: [String.t()]
  def supported_deployments, do: Map.values(@model_deployments)

  @spec project_binding_enabled?() :: boolean()
  def project_binding_enabled?, do: binding_enabled?(Config.settings!().codex.project_binding)

  @doc """
  Recompiles an already-shaped contract and compares its immutable identity.

  A struct tag is not authority: callers at an effect boundary must use this
  check before deriving provider parameters from a contract supplied by another
  process.
  """
  @spec verify(t()) :: {:ok, t()} | {:error, :invalid_task_launch_contract}
  def verify(%__MODULE__{} = contract) do
    attrs =
      contract
      |> Map.from_struct()
      |> Map.take([
        :programme,
        :repository,
        :issue_or_pr,
        :role,
        :task,
        :attempt,
        :fence,
        :exact_revision,
        :risk_assurance,
        :write_boundary,
        :evidence,
        :model_provider,
        :model_deployment,
        :provider_allocation_digest,
        :effort,
        :trigger,
        :goal_policy,
        :dependencies,
        :permissions,
        :evidence_gates,
        :stall_policy,
        :closeout_policy,
        :idempotency_identity,
        :conflict_identity,
        :commissioning_identity,
        :escalation,
        :supersedes,
        :project
      ])
      |> Map.put(:model, get_in(contract.executing_identity || %{}, [:model]))
      |> Map.merge(Map.take(contract.accountability || %{}, ~w(
        registry_id registry_version primary_role domain_alias authority_revision
        canonical_digest work_character permission_envelope execution_principal
        reviewer_principal integrator_principal candidate_id verdict_candidate_id
        verdict_attempt execution_fence verdict_exact_revision verdict_fence
        accepted_verdict receipt_identity receipt_fence handoff
      )))

    with {:ok, compiled} <- compile(attrs),
         true <-
           compiled.contract_id == contract.contract_id and
             compiled.executing_identity == contract.executing_identity and
             compiled.project == contract.project do
      {:ok, compiled}
    else
      _ -> {:error, :invalid_task_launch_contract}
    end
  end

  def verify(_), do: {:error, :invalid_task_launch_contract}

  @doc "Verifies that the prepared workspace still carries the contract revision."
  @spec verify_workspace(t() | nil, Path.t()) :: :ok | {:error, term()}
  def verify_workspace(nil, _workspace), do: :ok

  def verify_workspace(%__MODULE__{} = contract, workspace) when is_binary(workspace) do
    with {:ok, revision} <- workspace_revision(workspace),
         true <- revision == contract.exact_revision,
         :ok <- repository_matches?(workspace, contract.repository) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :workspace_contract_mismatch}
    end
  end

  def verify_workspace(_, _), do: {:error, :invalid_workspace_contract}

  @doc false
  @spec verify_fork_binding(t(), map(), Path.t(), String.t() | nil) :: :ok | {:error, :fork_authority_mismatch}
  def verify_fork_binding(%__MODULE__{} = contract, intent, workspace, worker_host)
      when is_map(intent) and is_binary(workspace) do
    source = Map.get(intent, :source, Map.get(intent, "source"))
    target = Map.get(intent, :target, Map.get(intent, "target"))
    host = worker_host || "local"

    expected = %{
      "task_id" => contract.task,
      "issue_identifier" => contract.issue_or_pr,
      "repository" => contract.repository,
      "revision" => contract.exact_revision,
      "native_project_id" => contract.project.native_project_id,
      "fence" => contract.fence,
      "attempt" => Integer.to_string(contract.attempt),
      "contract_id" => contract.contract_id,
      "title" => contract.title,
      "workspace_path" => workspace,
      "worker_host" => host
    }

    if is_map(source) and is_map(target) and is_binary(Map.get(source, :issue_id, Map.get(source, "issue_id"))) and
         Enum.all?(expected, fn {key, value} -> source_value(source, key) == value end) and
         Map.get(target, :worker_host, Map.get(target, "worker_host")) == host do
      :ok
    else
      {:error, :fork_authority_mismatch}
    end
  end

  def verify_fork_binding(_, _, _, _), do: {:error, :fork_authority_mismatch}

  defp source_value(source, key), do: Map.get(source, key, Map.get(source, source_key_atom(key)))
  defp source_key_atom("task_id"), do: :task_id
  defp source_key_atom("issue_identifier"), do: :issue_identifier
  defp source_key_atom("repository"), do: :repository
  defp source_key_atom("revision"), do: :revision
  defp source_key_atom("native_project_id"), do: :native_project_id
  defp source_key_atom("fence"), do: :fence
  defp source_key_atom("attempt"), do: :attempt
  defp source_key_atom("contract_id"), do: :contract_id
  defp source_key_atom("title"), do: :title
  defp source_key_atom("workspace_path"), do: :workspace_path
  defp source_key_atom("worker_host"), do: :worker_host

  @doc "Builds the only production contract source: workflow binding plus issue and workspace authority."
  def from_runtime(issue, workspace, opts \\ [])

  @spec from_runtime(map(), Path.t(), keyword()) :: {:ok, t() | nil} | {:error, term()}

  def from_runtime(issue, workspace, opts) when is_map(issue) and is_binary(workspace) and is_list(opts) do
    binding = Config.settings!().codex.project_binding

    if binding_enabled?(binding) do
      with {:ok, project} <- runtime_project(binding),
           {:ok, revision} <- workspace_revision(workspace),
           :ok <- repository_matches?(workspace, project.repository),
           {:ok, attrs} <- runtime_attrs(issue, workspace, project, revision, opts) do
        compile(attrs)
      end
    else
      if Keyword.get(opts, :repository_task, workspace_repository?(workspace)) do
        {:error, :project_binding_required_for_repository_task}
      else
        {:ok, nil}
      end
    end
  end

  def from_runtime(_, _, _), do: {:error, :invalid_runtime_launch_authority}

  @spec prompt(t(), String.t()) :: String.t()
  def prompt(%__MODULE__{} = contract, prompt) when is_binary(prompt) do
    """
    Symphony task launch contract (authoritative; do not reinterpret):
    contract_hash: #{contract.contract_id}
    repository: #{contract.repository}
    issue: #{contract.issue_or_pr}
    role: #{contract.role}
    revision: #{contract.exact_revision}
    attempt: #{contract.attempt}
    fence: #{contract.fence}
    executing_identity: #{Atom.to_string(contract.executing_identity.model)}/#{contract.executing_identity.effort}/#{contract.executing_identity.role}

    #{prompt}
    """
  end

  def prompt(_, _), do: ""

  @spec compile(map()) :: {:ok, t()} | {:error, [atom() | {atom(), term()}]}
  def compile(attrs) when is_map(attrs) do
    if ambiguous_keys?(attrs), do: {:error, [:ambiguous_contract_keys]}, else: compile_valid(stringify_keys(attrs))
  end

  def compile(_), do: {:error, [:contract_not_a_map]}

  defp compile_valid(attrs) do
    with {:ok, values} <- validate(attrs),
         {:ok, project} <- project_binding(values["project"], values["programme"]),
         {:ok, registry} <- TaskAccountabilityRegistry.compile(values),
         {:ok, identity} <- identity(values, project, registry) do
      title = title(values)
      executing_identity = executing_identity(identity, values, project, title, registry)

      {:ok,
       struct!(__MODULE__, %{
         contract_id: identity,
         programme: values["programme"],
         repository: values["repository"],
         issue_or_pr: values["issue_or_pr"],
         role: values["role"],
         task: values["task"],
         attempt: values["attempt"],
         fence: values["fence"],
         exact_revision: values["exact_revision"],
         risk_assurance: values["risk_assurance"],
         write_boundary: values["write_boundary"],
         evidence: values["evidence"],
         model_provider: values["model_provider"],
         model_deployment: values["model_deployment"],
         provider_allocation_digest: values["provider_allocation_digest"],
         effort: values["effort"],
         trigger: values["trigger"],
         goal_policy: values["goal_policy"],
         dependencies: values["dependencies"],
         permissions: values["permissions"],
         evidence_gates: values["evidence_gates"],
         stall_policy: values["stall_policy"],
         closeout_policy: values["closeout_policy"],
         idempotency_identity: values["idempotency_identity"],
         conflict_identity: values["conflict_identity"],
         commissioning_identity: values["commissioning_identity"],
         executing_identity: executing_identity,
         escalation: values["escalation"],
         supersedes: values["supersedes"],
         title: title,
         project: project,
         accountability: registry
       })}
    end
  end

  @spec compile_many([map()]) :: {:ok, [t()]} | {:error, term()}
  def compile_many(attrs) when is_list(attrs) do
    with {:ok, contracts} <- collect_compiled(attrs),
         :ok <- reject_duplicate_contracts(contracts) do
      {:ok, contracts}
    end
  end

  def compile_many(_), do: {:error, [:contracts_not_a_list]}

  @spec title(term()) :: String.t()
  def title(%__MODULE__{} = contract), do: contract.title

  def title(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    role = safe_title_part(attrs["role"], "task") |> String.replace("_", " ")
    issue = safe_title_part(attrs["issue_or_pr"], "work")
    task = safe_title_part(attrs["task"], "task")
    "#{String.capitalize(role)} #{issue}: #{task}" |> String.slice(0, 120)
  end

  def title(_), do: "Symphony task"

  defp validate(attrs) do
    required =
      ~w(programme repository issue_or_pr role task fence exact_revision write_boundary evidence model model_provider model_deployment provider_allocation_digest effort goal_policy dependencies permissions evidence_gates stall_policy closeout_policy idempotency_identity conflict_identity project)

    missing = Enum.filter(required, &blank?(attrs[&1]))

    if missing != [] do
      {:error, Enum.map(missing, &{:missing, String.to_existing_atom(&1)})}
    else
      attrs =
        attrs
        |> Map.put("commissioning_identity", normalize_commissioning(attrs["commissioning_identity"]))
        |> Map.put("escalation", normalize_escalation(attrs["escalation"]))
        |> Map.put("supersedes", normalize_supersession(attrs["supersedes"]))
        |> Map.put("risk_assurance", normalize_risk_assurance(attrs["risk_assurance"]))

      role = normalize_atom(attrs["role"])
      trigger = normalize_atom(attrs["trigger"] || "bounded")
      model = normalize_atom(attrs["model"])
      model_provider = normalize_atom(attrs["model_provider"])
      effort = normalize_atom(attrs["effort"])
      goal = normalize_atom(attrs["goal_policy"])
      boundary = normalize_atom(attrs["write_boundary"])
      attempt = attrs["attempt"] || 0

      errors =
        validation_errors(
          %{
            role: role,
            model: model,
            model_provider: model_provider,
            effort: effort,
            trigger: trigger,
            goal: goal,
            boundary: boundary,
            attempt: attempt
          },
          attrs
        )

      case errors do
        [] ->
          {:ok,
           Map.merge(attrs, %{
             "role" => role,
             "model" => model,
             "model_provider" => model_provider,
             "model_deployment" => attrs["model_deployment"],
             "provider_allocation_digest" => attrs["provider_allocation_digest"],
             "effort" => effort,
             "trigger" => trigger,
             "goal_policy" => goal,
             "write_boundary" => boundary,
             "attempt" => attempt,
             "risk_assurance" => attrs["risk_assurance"],
             "evidence" => normalize_evidence(attrs["evidence"]),
             "dependencies" => attrs["dependencies"],
             "permissions" => attrs["permissions"],
             "evidence_gates" => attrs["evidence_gates"],
             "stall_policy" => normalize_atom(attrs["stall_policy"]),
             "closeout_policy" => normalize_atom(attrs["closeout_policy"]),
             "commissioning_identity" => attrs["commissioning_identity"],
             "escalation" => attrs["escalation"],
             "supersedes" => attrs["supersedes"]
           })}

        errors ->
          {:error, Enum.reverse(errors)}
      end
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validation_errors(%{role: role, model: model, model_provider: model_provider, effort: effort, trigger: trigger, goal: goal, boundary: boundary, attempt: attempt}, attrs) do
    []
    |> add_unless(
      Enum.all?(~w(programme repository issue_or_pr task fence exact_revision idempotency_identity conflict_identity), &(is_binary(attrs[&1]) and String.trim(attrs[&1]) != "")),
      :invalid_string_field
    )
    |> add_unless(role in @roles, {:unsupported_role, role})
    |> add_unless(model in @models, {:unsupported_model, model})
    |> add_unless(model_provider in @model_providers, {:unsupported_model_provider, model_provider})
    |> add_unless(nonblank_string?(attrs["model_deployment"]), :invalid_model_deployment)
    |> add_unless(Map.get(@model_deployments, model) == attrs["model_deployment"], :model_deployment_mismatch)
    |> add_unless(receipt_digest?(attrs["provider_allocation_digest"]), :invalid_provider_allocation_digest)
    |> add_unless(effort in @efforts, {:unsupported_effort, effort})
    |> add_unless(trigger in (@luna_triggers ++ @terra_triggers ++ @sol_triggers), {:unsupported_trigger, trigger})
    |> add_unless(model_for_trigger?(model, effort, trigger), :model_trigger_mismatch)
    |> add_unless(goal in @goal_policies, {:unsupported_goal_policy, goal})
    |> add_unless(boundary in @write_domains, {:unsupported_write_boundary, boundary})
    |> add_unless(is_integer(attempt) and attempt >= 0, :invalid_attempt)
    |> add_unless(is_binary(attrs["exact_revision"]) and Regex.match?(~r/^[0-9a-f]{40}$/, attrs["exact_revision"]), :invalid_exact_revision)
    |> add_unless(valid_risk_assurance?(attrs["risk_assurance"], attrs["repository"], attrs["exact_revision"], role), :invalid_risk_assurance)
    |> add_unless(string_list?(attrs["dependencies"]), :invalid_dependencies)
    |> add_unless(string_list?(attrs["permissions"]), :invalid_permissions)
    |> add_unless(string_list?(attrs["evidence_gates"]), :invalid_evidence_gates)
    |> add_unless(string_list?(attrs["evidence"]), :invalid_evidence)
    |> add_unless(normalize_atom(attrs["stall_policy"]) in @stall_policies, :invalid_stall_policy)
    |> add_unless(normalize_atom(attrs["closeout_policy"]) in @closeout_policies, :invalid_closeout_policy)
    |> add_unless(is_binary(attrs["idempotency_identity"]), :invalid_idempotency_identity)
    |> add_unless(is_binary(attrs["conflict_identity"]), :invalid_conflict_identity)
    |> add_unless(valid_commissioning?(attrs["commissioning_identity"]), :invalid_commissioning_identity)
    |> add_unless(
      valid_escalation?(attrs["escalation"], trigger) or direct_human_commission?(attrs["commissioning_identity"]),
      :invalid_escalation_link
    )
    |> add_unless(valid_supersession?(attrs["supersedes"]), :invalid_supersession_identity)
    |> add_unless(role != :programme or goal == :programme, :programme_goal_required)
    |> add_unless(role == :programme or goal != :programme, :programme_goal_role_required)
    |> add_unless(goal != :worker or role in @worker_goal_roles, :worker_goal_role_invalid)
    |> add_unless(
      role not in [:independent_review, :landing, :monitor, :telemetry, :acceptance] or goal == :none,
      :role_requires_no_goal
    )
    |> add_unless(
      not escalation_trigger?(trigger) or direct_human_commission?(attrs["commissioning_identity"]) or
        valid_escalation?(attrs["escalation"], trigger),
      :escalation_link_required
    )
  end

  defp add_unless(errors, true, _error), do: errors
  defp add_unless(errors, false, error), do: [error | errors]

  defp model_for_trigger?(model, effort, trigger) do
    (trigger in @luna_triggers and model == :"gpt-5.6-luna" and effort == :medium) or
      (trigger in @terra_triggers and model == :"gpt-5.6-terra" and effort == :medium) or
      (trigger in @sol_triggers and model == :"gpt-5.6-sol" and effort in [:high, :xhigh, :max, :ultra])
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp project_binding(project, programme) when is_map(project) and is_binary(programme) do
    project_keys = Map.keys(project)
    normalized_keys = Enum.map(project_keys, &safe_key/1)

    if length(project_keys) != length(Enum.uniq(normalized_keys)) or
         Enum.any?(normalized_keys, &(&1 not in ~w(saved_project_id native_project_id repository root programme))) do
      {:error, [:unsupported_project_binding_field]}
    else
      project = stringify_keys(project)
      keys = ~w(saved_project_id native_project_id repository root programme)
      missing = Enum.filter(keys, &blank?(project[&1]))

      result =
        cond do
          missing != [] ->
            {:error, Enum.map(missing, &{:missing_project_binding, String.to_existing_atom(&1)})}

          project["saved_project_id"] == project["native_project_id"] ->
            {:error, [:project_namespaces_must_be_distinct]}

          not uuid?(project["saved_project_id"]) ->
            {:error, [:invalid_saved_project_id]}

          not uuid?(project["native_project_id"]) ->
            {:error, [:invalid_native_project_id]}

          project["repository"] == "" ->
            {:error, [:project_repository_mismatch]}

          project["programme"] != programme ->
            {:error, [:project_programme_mismatch]}

          not absolute_root?(project["root"]) ->
            {:error, [:project_root_must_be_absolute]}

          true ->
            {:ok,
             %{
               saved_project_id: project["saved_project_id"],
               native_project_id: project["native_project_id"],
               repository: project["repository"],
               root: Path.expand(project["root"]),
               programme: programme
             }}
        end

      result
    end
  end

  defp project_binding(_, _), do: {:error, [:project_binding_not_a_map]}

  defp identity(values, project, registry) do
    if values["repository"] != project.repository do
      {:error, [:repository_project_mismatch]}
    else
      encoded =
        [
          values["programme"],
          values["repository"],
          values["issue_or_pr"],
          values["role"],
          values["task"],
          values["exact_revision"],
          values["risk_assurance"],
          values["attempt"],
          values["write_boundary"],
          values["fence"],
          values["model"],
          values["model_provider"],
          values["model_deployment"],
          values["provider_allocation_digest"],
          values["effort"],
          values["trigger"],
          values["goal_policy"],
          values["dependencies"],
          values["permissions"],
          values["evidence_gates"],
          values["stall_policy"],
          values["closeout_policy"],
          values["idempotency_identity"],
          values["conflict_identity"],
          values["commissioning_identity"],
          values["escalation"],
          values["supersedes"],
          values["evidence"],
          project.saved_project_id,
          project.native_project_id,
          project.repository,
          project.root,
          registry.registry_id,
          registry.registry_version,
          registry.primary_role,
          registry.domain_alias,
          registry.authority_revision,
          registry.work_character,
          registry.permission_envelope,
          registry,
          values["execution_principal"],
          values["reviewer_principal"],
          values["integrator_principal"],
          values["candidate_id"],
          values["verdict_candidate_id"],
          values["verdict_attempt"],
          values["verdict_exact_revision"],
          values["execution_fence"],
          values["verdict_fence"],
          values["accepted_verdict"],
          values["receipt_identity"],
          values["receipt_fence"],
          values["handoff"]
        ]
        |> :erlang.term_to_binary()

      {:ok, "tlc-" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)}
    end
  end

  defp collect_compiled(attrs),
    do:
      Enum.reduce_while(attrs, {:ok, []}, fn attrs, {:ok, acc} ->
        case compile(attrs) do
          {:ok, contract} -> {:cont, {:ok, [contract | acc]}}
          {:error, errors} -> {:halt, {:error, errors}}
        end
      end)

  defp reject_duplicate_contracts(contracts) do
    ids = Enum.map(contracts, & &1.contract_id)
    if length(ids) == MapSet.size(MapSet.new(ids)), do: :ok, else: {:error, [:duplicate_contract_identity]}
  end

  defp normalize_evidence(nil), do: []
  defp normalize_evidence(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp normalize_evidence(_), do: []
  defp string_list?(values), do: is_list(values) and Enum.all?(values, &is_binary/1)

  defp ambiguous_keys?(attrs) do
    keys = Map.keys(attrs)
    normalized = Enum.map(keys, &safe_key/1)

    length(keys) != length(Enum.uniq(normalized)) or
      Enum.any?(
        normalized,
        &(&1 not in ~w(programme repository issue_or_pr role task attempt fence execution_fence exact_revision risk_assurance write_boundary evidence model model_provider model_deployment provider_allocation_digest effort trigger goal_policy dependencies permissions evidence_gates stall_policy closeout_policy idempotency_identity conflict_identity commissioning_identity escalation supersedes project registry_id registry_version primary_role domain_alias authority_revision canonical_digest work_character permission_envelope execution_principal reviewer_principal integrator_principal candidate_id verdict_candidate_id verdict_attempt verdict_exact_revision verdict_fence accepted_verdict receipt_identity receipt_fence handoff))
      )
  end

  defp normalize_atom(value) when is_atom(value), do: value

  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  defp normalize_atom(value) when is_binary(value) do
    supported = @roles ++ @models ++ @model_providers ++ @goal_policies ++ @write_domains ++ @efforts
    supported = supported ++ @stall_policies ++ @closeout_policies
    supported = supported ++ @luna_triggers ++ @terra_triggers ++ @sol_triggers
    Enum.find(supported, &(to_string(&1) == value))
  end

  defp normalize_atom(_), do: nil
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
  defp absolute_root?(root) when is_binary(root), do: Path.type(root) == :absolute
  defp absolute_root?(_), do: false
  defp uuid?(value) when is_binary(value), do: Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, value)
  defp uuid?(_), do: false
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {safe_key(key), value} end)
  defp safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp safe_key(key) when is_binary(key), do: key
  defp safe_key(_), do: nil

  defp safe_title_part(value, _fallback) when is_binary(value), do: String.slice(value, 0, 80)
  defp safe_title_part(value, _fallback) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp safe_title_part(_, fallback), do: fallback

  defp normalize_commissioning(nil), do: nil
  defp normalize_commissioning(value) when is_map(value), do: stringify_keys(value)
  defp normalize_commissioning(_), do: :invalid
  defp normalize_escalation(nil), do: nil
  defp normalize_escalation(value) when is_map(value), do: stringify_keys(value)
  defp normalize_escalation(_), do: :invalid
  defp normalize_supersession(nil), do: nil
  defp normalize_supersession(value) when is_map(value), do: stringify_keys(value)
  defp normalize_supersession(_), do: :invalid
  defp normalize_risk_assurance(nil), do: nil

  defp normalize_risk_assurance(value) when is_map(value) do
    keys = Map.keys(value)
    normalized_keys = Enum.map(keys, &safe_key/1)

    if length(keys) != length(Enum.uniq(normalized_keys)) or Enum.any?(normalized_keys, &is_nil/1) do
      :invalid
    else
      Map.new(value, fn {key, child} -> {safe_key(key), child} end)
    end
  end

  defp normalize_risk_assurance(_), do: :invalid

  @risk_assurance_keys ~w(
    artifact_url assurance_outcome assurance_receipt_digest evidence_manifest_digest
    head_sha matrix_revision repository required_gate_ids risk_receipt_digest schema stage
  )

  defp valid_risk_assurance?(nil, _repository, _head, role), do: role not in [:independent_review, :landing]

  defp valid_risk_assurance?(projection, repository, head, role)
       when is_map(projection) and role in [:independent_review, :landing] do
    checks = [
      Enum.sort(Map.keys(projection)) == Enum.sort(@risk_assurance_keys),
      projection["schema"] == "sysmiq.symphony.risk-assurance.v1",
      projection["repository"] == repository,
      projection["head_sha"] == head,
      receipt_digest?(projection["risk_receipt_digest"]),
      receipt_digest?(projection["assurance_receipt_digest"]),
      receipt_digest?(projection["evidence_manifest_digest"]),
      nonblank_string?(projection["matrix_revision"]),
      valid_required_gate_ids?(projection["required_gate_ids"]),
      artifact_url?(projection["artifact_url"], repository, head),
      valid_risk_assurance_stage?(projection, role)
    ]

    Enum.all?(checks)
  end

  defp valid_risk_assurance?(_, _, _, _), do: false
  defp valid_risk_assurance_stage?(%{"stage" => "review", "assurance_outcome" => "unresolved"}, :independent_review), do: true
  defp valid_risk_assurance_stage?(%{"stage" => "landing", "assurance_outcome" => "pass"}, :landing), do: true
  defp valid_risk_assurance_stage?(_, _), do: false
  defp receipt_digest?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value)

  defp valid_required_gate_ids?(value) do
    is_list(value) and value != [] and length(value) <= 32 and Enum.all?(value, &valid_gate_id?/1)
  end

  defp valid_gate_id?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z][A-Za-z0-9_.:-]{0,127}$/, value)

  defp artifact_url?(url, repository, _head) when is_binary(url) do
    uri = URI.parse(url)

    valid_artifact_uri?(uri) and valid_artifact_path?(uri.path, repository)
  rescue
    _ -> false
  end

  defp artifact_url?(_, _, _), do: false

  defp valid_artifact_uri?(uri) do
    uri.scheme == "https" and uri.host == "github.com" and is_nil(uri.userinfo) and
      is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp valid_artifact_path?(path, repository) do
    case String.split(path || "", "/", trim: true) do
      [owner, repo, "actions", "runs", run_id, "artifacts"] ->
        owner <> "/" <> repo == repository and run_id =~ ~r/^\d+$/

      _ ->
        false
    end
  end

  defp valid_commissioning?(nil), do: true

  defp valid_commissioning?(%{"kind" => "human", "authority" => authority} = identity),
    do: Map.keys(identity) |> Enum.sort() == ["authority", "kind"] and nonblank_string?(authority)

  defp valid_commissioning?(%{"kind" => "agent", "contract_id" => id, "task_id" => task_id, "role" => role, "model" => model, "effort" => effort} = identity) do
    Map.keys(identity) |> Enum.sort() == ["contract_id", "effort", "kind", "model", "role", "task_id"] and
      contract_id?(id) and nonblank_string?(task_id) and normalize_atom(role) in @roles and
      normalize_atom(model) in @models and normalize_atom(effort) in @efforts
  end

  defp valid_commissioning?(_), do: false

  defp direct_human_commission?(identity) when is_map(identity),
    do: valid_commissioning?(identity) and Map.get(identity, "kind") == "human"

  defp direct_human_commission?(_), do: false
  defp escalation_trigger?(trigger), do: trigger in (@terra_triggers ++ @sol_triggers)
  defp valid_escalation?(nil, trigger), do: not escalation_trigger?(trigger)

  defp valid_escalation?(
         %{"prior_contract_id" => id, "prior_task_id" => task_id, "prior_role" => role, "prior_model" => model, "prior_effort" => effort, "trigger" => trigger, "reason" => reason} = link,
         target_trigger
       ) do
    Map.keys(link) |> Enum.sort() == ["prior_contract_id", "prior_effort", "prior_model", "prior_role", "prior_task_id", "reason", "trigger"] and
      contract_id?(id) and nonblank_string?(task_id) and normalize_atom(role) in @roles and
      normalize_atom(model) == :"gpt-5.6-luna" and normalize_atom(effort) == :medium and
      normalize_atom(trigger) == target_trigger and nonblank_string?(reason)
  end

  defp valid_escalation?(_, _), do: false
  defp valid_supersession?(nil), do: true

  defp valid_supersession?(%{"contract_id" => id, "resolution" => resolution} = value),
    do: Map.keys(value) |> Enum.sort() == ["contract_id", "resolution"] and contract_id?(id) and nonblank_string?(resolution)

  defp valid_supersession?(_), do: false
  defp contract_id?(value), do: is_binary(value) and Regex.match?(~r/^tlc-[0-9a-f]{64}$/, value)
  defp nonblank_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp executing_identity(contract_id, values, project, title, registry),
    do: %{
      contract_id: contract_id,
      task: values["task"],
      title: title,
      model: values["model"],
      model_provider: values["model_provider"],
      model_deployment: values["model_deployment"],
      provider_allocation_digest: values["provider_allocation_digest"],
      effort: values["effort"],
      role: values["role"],
      issue_or_pr: values["issue_or_pr"],
      exact_revision: values["exact_revision"],
      attempt: values["attempt"],
      fence: values["fence"],
      project: project,
      registry_id: registry.registry_id,
      registry_version: registry.registry_version,
      primary_role: registry.primary_role,
      domain_alias: registry.domain_alias,
      authority_revision: registry.authority_revision,
      work_character: registry.work_character,
      permission_envelope: registry.permission_envelope
    }

  defp binding_enabled?(%{enabled: true}), do: true
  defp binding_enabled?(%{"enabled" => true}), do: true
  defp binding_enabled?(_), do: false

  defp runtime_project(binding) do
    project = Map.take(Map.from_struct(binding), [:saved_project_id, :native_project_id, :repository, :root, :programme])
    project_binding(project, Map.get(project, :programme))
  rescue
    Protocol.UndefinedError -> {:error, :invalid_project_binding}
  end

  defp workspace_revision(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> {:ok, String.trim(revision)}
      _ -> {:error, :workspace_revision_unavailable}
    end
  rescue
    ErlangError -> {:error, :workspace_revision_unavailable}
  end

  defp workspace_repository?(workspace) when is_binary(workspace) do
    match?({_output, 0}, System.cmd("git", ["-C", workspace, "rev-parse", "--is-inside-work-tree"], stderr_to_stdout: true))
  rescue
    ErlangError -> false
  end

  defp repository_matches?(workspace, repository) do
    case System.cmd("git", ["-C", workspace, "config", "--get", "remote.origin.url"], stderr_to_stdout: true) do
      {remote, 0} -> if repository_name(String.trim(remote)) == repository, do: :ok, else: {:error, :workspace_repository_mismatch}
      _ -> {:error, :workspace_repository_unavailable}
    end
  rescue
    ErlangError -> {:error, :workspace_repository_unavailable}
  end

  defp repository_name(remote) when is_binary(remote) do
    remote
    |> String.replace(~r/^git@[^:]+:/, "")
    |> String.replace(~r|^https?://[^/]+/|, "")
    |> String.replace_suffix(".git", "")
  end

  defp runtime_attrs(issue, workspace, project, revision, opts) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier")
    title = Map.get(issue, :title) || Map.get(issue, "title")
    attempt = Keyword.get(opts, :attempt, 0)
    role = Keyword.get(opts, :role, :implementation)
    trigger = Keyword.get(opts, :trigger, :bounded)
    commissioning_identity = Keyword.get(opts, :commissioning_identity)
    escalation = Keyword.get(opts, :escalation)
    supersedes = Keyword.get(opts, :supersedes)
    {model, effort} = model_for_trigger(trigger)
    model_provider = Config.settings!().codex.model_provider
    model_deployment = deployment_for_model(model)
    provider_allocation_digest = Config.settings!().codex.provider_allocation_digest

    if is_binary(identifier) and is_binary(title) and is_integer(attempt) and attempt >= 0 do
      {:ok,
       %{
         programme: project.programme,
         repository: project.repository,
         issue_or_pr: identifier,
         role: role,
         task: title,
         attempt: attempt,
         fence: "#{identifier}:#{attempt}:#{revision}",
         exact_revision: revision,
         risk_assurance: Keyword.get(opts, :risk_assurance),
         write_boundary: :product,
         evidence: ["change_record", "test_or_quality_evidence"],
         model: model,
         model_provider: model_provider,
         model_deployment: model_deployment,
         provider_allocation_digest: provider_allocation_digest,
         effort: effort,
         trigger: trigger,
         goal_policy: if(role in @worker_goal_roles, do: :worker, else: :none),
         dependencies: [],
         permissions: ["workspace-write"],
         evidence_gates: ["project-bound-readback"],
         stall_policy: :fail_closed,
         closeout_policy: :reconcile,
         idempotency_identity: "#{identifier}/#{role}/#{revision}/#{attempt}",
         conflict_identity: "#{project.repository}:#{identifier}:#{role}:#{revision}",
         commissioning_identity: commissioning_identity,
         escalation: escalation,
         supersedes: supersedes,
         project: Map.put(project, :root, workspace),
         registry_id: TaskAccountabilityRegistry.identity().registry_id,
         registry_version: TaskAccountabilityRegistry.identity().registry_version,
         canonical_digest: TaskAccountabilityRegistry.identity().canonical_digest,
         primary_role: Atom.to_string(role),
         domain_alias: Keyword.get(opts, :domain_alias, default_domain_alias(role)),
         authority_revision: TaskAccountabilityRegistry.identity().authority_revision,
         work_character: Keyword.get(opts, :work_character, "bounded"),
         permission_envelope: Keyword.get(opts, :permission_envelope, ["write_bound_scope"]),
         execution_principal: Keyword.get(opts, :execution_principal),
         reviewer_principal: Keyword.get(opts, :reviewer_principal),
         integrator_principal: Keyword.get(opts, :integrator_principal),
         candidate_id: Keyword.get(opts, :candidate_id, identifier),
         verdict_candidate_id: Keyword.get(opts, :verdict_candidate_id),
         verdict_attempt: Keyword.get(opts, :verdict_attempt),
         execution_fence: Keyword.get(opts, :execution_fence, "#{identifier}:#{attempt}:#{revision}"),
         verdict_exact_revision: Keyword.get(opts, :verdict_exact_revision),
         verdict_fence: Keyword.get(opts, :verdict_fence),
         accepted_verdict: Keyword.get(opts, :accepted_verdict),
         receipt_identity: Keyword.get(opts, :receipt_identity),
         receipt_fence: Keyword.get(opts, :receipt_fence),
         handoff: Keyword.get(opts, :handoff)
       }}
    else
      {:error, :invalid_issue_authority}
    end
  end

  defp model_for_trigger(trigger) when trigger in @terra_triggers, do: {:"gpt-5.6-terra", :medium}
  defp model_for_trigger(trigger) when trigger in @sol_triggers, do: {:"gpt-5.6-sol", :high}
  defp model_for_trigger(_), do: {:"gpt-5.6-luna", :medium}

  defp default_domain_alias(:implementation), do: "implementation worker"
  defp default_domain_alias(:independent_review), do: "independent review"
  defp default_domain_alias(:landing), do: "landing"
  defp default_domain_alias(:recovery), do: "recovery owner"
  defp default_domain_alias(:monitor), do: "monitor"
  defp default_domain_alias(:telemetry), do: "telemetry"
  defp default_domain_alias(:research), do: "research"
  defp default_domain_alias(:programme), do: "programme"
  defp default_domain_alias(:acceptance), do: "acceptance"
  defp default_domain_alias(role), do: Atom.to_string(role)
end
