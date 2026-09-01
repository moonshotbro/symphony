defmodule SymphonyElixir.Codex.TaskLaunchContract do
  @moduledoc """
  Pure compiler for the bounded identity carried by a Codex task launch.

  This module deliberately does not create or inspect App Server tasks.  It
  validates the authority boundary before a caller enters that effectful path.
  """

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
  @type executing_identity :: %{role: role(), model: atom(), effort: atom(), title: String.t()}
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
          write_boundary: atom(),
          evidence: [String.t()],
          model: atom(),
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
          commissioning_identity: executing_identity() | nil,
          executing_identity: executing_identity(),
          supersedes: String.t() | nil,
          title: String.t(),
          project: saved_project_binding()
        }

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
    :write_boundary,
    :evidence,
    :model,
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
    :supersedes,
    :project
  ]

  @spec supported_roles() :: [role()]
  def supported_roles, do: @roles

  @spec supported_models() :: [atom()]
  def supported_models, do: @models

  @spec project_binding_enabled?() :: boolean()
  def project_binding_enabled?, do: binding_enabled?(Config.settings!().codex.project_binding)

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
      {:ok, nil}
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
         {:ok, identity} <- identity(values, project) do
      title = title(values)
      executing_identity = %{role: values["role"], model: values["model"], effort: values["effort"], title: title}

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
         write_boundary: values["write_boundary"],
         evidence: values["evidence"],
         model: values["model"],
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
         supersedes: values["supersedes"],
         title: title,
         project: project
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
      ~w(programme repository issue_or_pr role task fence exact_revision write_boundary evidence model effort goal_policy dependencies permissions evidence_gates stall_policy closeout_policy idempotency_identity conflict_identity project)

    missing = Enum.filter(required, &blank?(attrs[&1]))

    if missing != [] do
      {:error, Enum.map(missing, &{:missing, String.to_existing_atom(&1)})}
    else
      role = normalize_atom(attrs["role"])
      trigger = normalize_atom(attrs["trigger"] || "bounded")
      model = normalize_atom(attrs["model"])
      effort = normalize_atom(attrs["effort"])
      goal = normalize_atom(attrs["goal_policy"])
      boundary = normalize_atom(attrs["write_boundary"])
      attempt = attrs["attempt"] || 0
      errors = validation_errors(role, model, effort, trigger, goal, boundary, attempt, attrs)

      case errors do
        [] ->
          {:ok,
           Map.merge(attrs, %{
             "role" => role,
             "model" => model,
             "effort" => effort,
             "trigger" => trigger,
             "goal_policy" => goal,
             "write_boundary" => boundary,
             "attempt" => attempt,
             "evidence" => normalize_evidence(attrs["evidence"]),
             "dependencies" => attrs["dependencies"],
             "permissions" => attrs["permissions"],
             "evidence_gates" => attrs["evidence_gates"],
             "stall_policy" => normalize_atom(attrs["stall_policy"]),
             "closeout_policy" => normalize_atom(attrs["closeout_policy"]),
             "commissioning_identity" => attrs["commissioning_identity"],
             "supersedes" => attrs["supersedes"]
           })}

        errors ->
          {:error, Enum.reverse(errors)}
      end
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validation_errors(role, model, effort, trigger, goal, boundary, attempt, attrs) do
    []
    |> add_unless(
      Enum.all?(~w(programme repository issue_or_pr task fence exact_revision idempotency_identity conflict_identity), &(is_binary(attrs[&1]) and String.trim(attrs[&1]) != "")),
      :invalid_string_field
    )
    |> add_unless(role in @roles, {:unsupported_role, role})
    |> add_unless(model in @models, {:unsupported_model, model})
    |> add_unless(effort in @efforts, {:unsupported_effort, effort})
    |> add_unless(trigger in (@luna_triggers ++ @terra_triggers ++ @sol_triggers), {:unsupported_trigger, trigger})
    |> add_unless(model_for_trigger?(model, effort, trigger), :model_trigger_mismatch)
    |> add_unless(goal in @goal_policies, {:unsupported_goal_policy, goal})
    |> add_unless(boundary in @write_domains, {:unsupported_write_boundary, boundary})
    |> add_unless(is_integer(attempt) and attempt >= 0, :invalid_attempt)
    |> add_unless(is_binary(attrs["exact_revision"]) and Regex.match?(~r/^[0-9a-f]{40}$/, attrs["exact_revision"]), :invalid_exact_revision)
    |> add_unless(string_list?(attrs["dependencies"]), :invalid_dependencies)
    |> add_unless(string_list?(attrs["permissions"]), :invalid_permissions)
    |> add_unless(string_list?(attrs["evidence_gates"]), :invalid_evidence_gates)
    |> add_unless(string_list?(attrs["evidence"]), :invalid_evidence)
    |> add_unless(normalize_atom(attrs["stall_policy"]) in @stall_policies, :invalid_stall_policy)
    |> add_unless(normalize_atom(attrs["closeout_policy"]) in @closeout_policies, :invalid_closeout_policy)
    |> add_unless(is_binary(attrs["idempotency_identity"]), :invalid_idempotency_identity)
    |> add_unless(is_binary(attrs["conflict_identity"]), :invalid_conflict_identity)
    |> add_unless(valid_identity?(attrs["commissioning_identity"]), :invalid_commissioning_identity)
    |> add_unless(is_nil(attrs["supersedes"]) or is_binary(attrs["supersedes"]), :invalid_supersession_identity)
    |> add_unless(role != :programme or goal == :programme, :programme_goal_required)
    |> add_unless(role == :programme or goal != :programme, :programme_goal_role_required)
    |> add_unless(goal != :worker or role in @worker_goal_roles, :worker_goal_role_invalid)
    |> add_unless(
      role not in [:independent_review, :landing, :monitor, :telemetry, :acceptance] or goal == :none,
      :role_requires_no_goal
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

  defp identity(values, project) do
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
          values["attempt"],
          values["write_boundary"],
          values["fence"],
          values["model"],
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
          values["role"],
          values["supersedes"],
          values["evidence"],
          project.saved_project_id,
          project.native_project_id,
          project.repository,
          project.root
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
        &(&1 not in ~w(programme repository issue_or_pr role task attempt fence exact_revision write_boundary evidence model effort trigger goal_policy dependencies permissions evidence_gates stall_policy closeout_policy idempotency_identity conflict_identity commissioning_identity supersedes project))
      )
  end

  defp normalize_atom(value) when is_atom(value), do: value

  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  defp normalize_atom(value) when is_binary(value) do
    supported = @roles ++ @models ++ @goal_policies ++ @write_domains ++ @efforts
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

  defp valid_identity?(nil), do: true

  defp valid_identity?(%{role: role, model: model, effort: effort, title: title}),
    do: role in @roles and model in @models and effort in @efforts and is_binary(title)

  defp valid_identity?(_), do: false

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
    {model, effort} = model_for_trigger(trigger)

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
         write_boundary: :product,
         evidence: [],
         model: model,
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
         commissioning_identity: nil,
         supersedes: nil,
         project: Map.put(project, :root, workspace)
       }}
    else
      {:error, :invalid_issue_authority}
    end
  end

  defp model_for_trigger(trigger) when trigger in @terra_triggers, do: {:"gpt-5.6-terra", :medium}
  defp model_for_trigger(trigger) when trigger in @sol_triggers, do: {:"gpt-5.6-sol", :high}
  defp model_for_trigger(_), do: {:"gpt-5.6-luna", :medium}
end
