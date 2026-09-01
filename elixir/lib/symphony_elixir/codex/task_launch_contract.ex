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
          goal_policy: goal_policy(),
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
    :goal_policy,
    :title,
    :project
  ]

  @spec supported_roles() :: [role()]
  def supported_roles, do: @roles

  @spec supported_models() :: [atom()]
  def supported_models, do: @models

  @spec compile(map()) :: {:ok, t()} | {:error, [atom() | {atom(), term()}]}
  def compile(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

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
         goal_policy: values["goal_policy"],
         title: title,
         project: project
       })}
    end
  end

  def compile(_), do: {:error, [:contract_not_a_map]}

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
    required = ~w(programme repository issue_or_pr role task fence exact_revision write_boundary model goal_policy project)
    missing = Enum.filter(required, &blank?(attrs[&1]))

    if missing != [] do
      {:error, Enum.map(missing, &{:missing, String.to_existing_atom(&1)})}
    else
      role = normalize_atom(attrs["role"])
      model = normalize_atom(attrs["model"])
      goal = normalize_atom(attrs["goal_policy"])
      boundary = normalize_atom(attrs["write_boundary"])
      attempt = attrs["attempt"] || 0
      errors = validation_errors(role, model, goal, boundary, attempt)

      case errors do
        [] ->
          {:ok,
           Map.merge(attrs, %{
             "role" => role,
             "model" => model,
             "goal_policy" => goal,
             "write_boundary" => boundary,
             "attempt" => attempt,
             "evidence" => normalize_evidence(attrs["evidence"])
           })}

        errors ->
          {:error, Enum.reverse(errors)}
      end
    end
  end

  defp validation_errors(role, model, goal, boundary, attempt) do
    []
    |> add_unless(role in @roles, {:unsupported_role, role})
    |> add_unless(model in @models, {:unsupported_model, model})
    |> add_unless(goal in @goal_policies, {:unsupported_goal_policy, goal})
    |> add_unless(boundary in @write_domains, {:unsupported_write_boundary, boundary})
    |> add_unless(is_integer(attempt) and attempt >= 0, :invalid_attempt)
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

  defp project_binding(project) when is_map(project) do
    project = stringify_keys(project)
    keys = ~w(saved_project_id native_project_id repository root)
    missing = Enum.filter(keys, &blank?(project[&1]))

    cond do
      missing != [] -> {:error, Enum.map(missing, &{:missing_project_binding, String.to_existing_atom(&1)})}
      project["saved_project_id"] == project["native_project_id"] -> {:error, [:project_namespaces_must_be_distinct]}
      project["repository"] == "" -> {:error, [:project_repository_mismatch]}
      not absolute_root?(project["root"]) -> {:error, [:project_root_must_be_absolute]}
      true -> {:ok, %{saved_project_id: project["saved_project_id"], native_project_id: project["native_project_id"], repository: project["repository"], root: Path.expand(project["root"])}}
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
          values["exact_revision"],
          values["attempt"],
          values["write_boundary"],
          values["fence"],
          project.saved_project_id,
          project.native_project_id
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
