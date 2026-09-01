defmodule SymphonyElixir.Codex.TaskLaunchContract do
  @moduledoc """
  Pure compiler for the bounded identity carried by a Codex task launch.

  This module deliberately does not create or inspect App Server tasks.  It
  validates the authority boundary before a caller enters that effectful path.
  """

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
          root: Path.t()
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
          write_boundary: atom(),
          evidence: [String.t()],
          model: atom(),
          effort: atom(),
          goal_policy: goal_policy(),
          dependencies: [String.t()],
          permissions: [String.t()],
          evidence_gates: [String.t()],
          stall_policy: atom(),
          closeout_policy: atom(),
          idempotency_identity: String.t(),
          conflict_identity: String.t(),
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
    :goal_policy,
    :title,
    :dependencies,
    :permissions,
    :evidence_gates,
    :stall_policy,
    :closeout_policy,
    :idempotency_identity,
    :conflict_identity,
    :project
  ]

  @spec supported_roles() :: [role()]
  def supported_roles, do: @roles

  @spec supported_models() :: [atom()]
  def supported_models, do: @models

  @spec compile(map()) :: {:ok, t()} | {:error, [atom() | {atom(), term()}]}
  def compile(attrs) when is_map(attrs) do
    if ambiguous_keys?(attrs), do: {:error, [:ambiguous_contract_keys]}, else: compile_valid(stringify_keys(attrs))
  end

  def compile(_), do: {:error, [:contract_not_a_map]}

  defp compile_valid(attrs) do
    with {:ok, values} <- validate(attrs),
         {:ok, project} <- project_binding(values["project"]),
         {:ok, identity} <- identity(values, project) do
      title = title(values)

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
         goal_policy: values["goal_policy"],
         dependencies: values["dependencies"],
         permissions: values["permissions"],
         evidence_gates: values["evidence_gates"],
         stall_policy: values["stall_policy"],
         closeout_policy: values["closeout_policy"],
         idempotency_identity: values["idempotency_identity"],
         conflict_identity: values["conflict_identity"],
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

  @spec title(t() | map()) :: String.t()
  def title(%__MODULE__{} = contract), do: contract.title

  def title(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    role = attrs["role"] |> to_string() |> String.replace("_", " ")
    issue = attrs["issue_or_pr"] || "work"
    task = attrs["task"] || "task"
    "#{String.capitalize(role)} #{issue}: #{task}" |> String.slice(0, 120)
  end

  defp validate(attrs) do
    required =
      ~w(programme repository issue_or_pr role task fence exact_revision write_boundary evidence model effort goal_policy dependencies permissions evidence_gates stall_policy closeout_policy idempotency_identity conflict_identity project)

    missing = Enum.filter(required, &blank?(attrs[&1]))

    if missing != [] do
      {:error, Enum.map(missing, &{:missing, String.to_existing_atom(&1)})}
    else
      role = normalize_atom(attrs["role"])
      model = normalize_atom(attrs["model"])
      effort = normalize_atom(attrs["effort"])
      goal = normalize_atom(attrs["goal_policy"])
      boundary = normalize_atom(attrs["write_boundary"])
      attempt = attrs["attempt"] || 0
      errors = validation_errors(role, model, effort, goal, boundary, attempt, attrs)

      case errors do
        [] ->
          {:ok,
           Map.merge(attrs, %{
             "role" => role,
             "model" => model,
             "effort" => effort,
             "goal_policy" => goal,
             "write_boundary" => boundary,
             "attempt" => attempt,
             "evidence" => normalize_evidence(attrs["evidence"]),
             "dependencies" => attrs["dependencies"],
             "permissions" => attrs["permissions"],
             "evidence_gates" => attrs["evidence_gates"],
             "stall_policy" => normalize_atom(attrs["stall_policy"]),
             "closeout_policy" => normalize_atom(attrs["closeout_policy"])
           })}

        errors ->
          {:error, Enum.reverse(errors)}
      end
    end
  end

  defp validation_errors(role, model, effort, goal, boundary, attempt, attrs) do
    []
    |> add_unless(
      Enum.all?(~w(programme repository issue_or_pr task fence exact_revision idempotency_identity conflict_identity), &(is_binary(attrs[&1]) and String.trim(attrs[&1]) != "")),
      :invalid_string_field
    )
    |> add_unless(role in @roles, {:unsupported_role, role})
    |> add_unless(model in @models, {:unsupported_model, model})
    |> add_unless(effort in @efforts, {:unsupported_effort, effort})
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

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp project_binding(project) when is_map(project) do
    project_keys = Map.keys(project)
    normalized_keys = Enum.map(project_keys, &to_string/1)

    if length(project_keys) != length(Enum.uniq(normalized_keys)) or
         Enum.any?(normalized_keys, &(&1 not in ~w(saved_project_id native_project_id repository root))) do
      {:error, [:unsupported_project_binding_field]}
    else
      project = stringify_keys(project)
      keys = ~w(saved_project_id native_project_id repository root)
      missing = Enum.filter(keys, &blank?(project[&1]))

      result =
        cond do
          missing != [] -> {:error, Enum.map(missing, &{:missing_project_binding, String.to_existing_atom(&1)})}
          project["saved_project_id"] == project["native_project_id"] -> {:error, [:project_namespaces_must_be_distinct]}
          not Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, project["saved_project_id"]) -> {:error, [:invalid_saved_project_id]}
          not Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, project["native_project_id"]) -> {:error, [:invalid_native_project_id]}
          project["repository"] == "" -> {:error, [:project_repository_mismatch]}
          not absolute_root?(project["root"]) -> {:error, [:project_root_must_be_absolute]}
          true -> {:ok, %{saved_project_id: project["saved_project_id"], native_project_id: project["native_project_id"], repository: project["repository"], root: Path.expand(project["root"])}}
        end

      result
    end
  end

  defp project_binding(_), do: {:error, [:project_binding_not_a_map]}

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
          values["goal_policy"],
          values["dependencies"],
          values["permissions"],
          values["evidence_gates"],
          values["stall_policy"],
          values["closeout_policy"],
          values["idempotency_identity"],
          values["conflict_identity"],
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
    normalized = Enum.map(keys, &to_string/1)

    length(keys) != length(Enum.uniq(normalized)) or
      Enum.any?(
        normalized,
        &(&1 not in ~w(programme repository issue_or_pr role task attempt fence exact_revision write_boundary evidence model effort goal_policy dependencies permissions evidence_gates stall_policy closeout_policy idempotency_identity conflict_identity project))
      )
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    Enum.find(@roles ++ @models ++ @goal_policies ++ @write_domains, &(to_string(&1) == value))
  end

  defp normalize_atom(_), do: nil
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
  defp absolute_root?(root) when is_binary(root), do: Path.type(root) == :absolute
  defp absolute_root?(_), do: false
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
