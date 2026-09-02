defmodule SymphonyElixir.Toscanini.ControlCLI do
  @moduledoc """
  Fixed stdio bridge for the bounded Toscanini control-plane boundary.

  The bridge accepts exactly one operation argument and one JSON object on
  stdin. Provider-facing operations remain explicitly parent-owned; returning
  that boundary is safer than pretending a local process can prove an App
  Server, GitHub, or programme side effect.
  """

  alias SymphonyElixir.Toscanini.ControlPlane

  @operations ~w(programme_status construct_task dispatch_task reconcile_programme recover_task review_exact_head land_exact_head cleanup_task)
  @parent_owned ~w(programme_status dispatch_task reconcile_programme recover_task review_exact_head land_exact_head cleanup_task)

  @spec operations() :: [String.t()]
  def operations, do: @operations

  @spec main([String.t()]) :: :ok
  def main([operation]) when operation in @operations do
    request = IO.read(:stdio, :eof) |> Jason.decode()
    result = invoke(operation, request)
    IO.write(Jason.encode!(result))
    :ok
  end

  def main(_args) do
    IO.write(Jason.encode!(%{"ok" => false, "error" => "operation_required", "operations" => @operations}))
    :ok
  end

  @spec invoke(String.t(), {:ok, map()} | {:error, term()}) :: map()
  def invoke(operation, {:ok, request}) when operation in @operations and is_map(request) do
    identity = identity_echo(request)

    cond do
      operation in @parent_owned -> Map.merge(identity, %{"ok" => false, "error" => "parent_owned_operation"})
      operation == "construct_task" -> construct(identity, request)
      true -> Map.merge(identity, %{"ok" => false, "error" => "unsupported_operation"})
    end
  end

  def invoke(operation, {:ok, _request}), do: %{"ok" => false, "operation" => operation, "error" => "request_object_required"}
  def invoke(operation, {:error, _reason}), do: %{"ok" => false, "operation" => operation, "error" => "invalid_json"}
  def invoke(operation, _request), do: %{"ok" => false, "operation" => operation, "error" => "invalid_request"}

  defp construct(identity, request) do
    issue = %{
      "identifier" => Map.get(request, "issue_identifier") || issue_identifier(request),
      "title" => Map.get(request, "objective")
    }

    opts = [role: runtime_role(Map.get(request, "role")), trigger: runtime_trigger(Map.get(request, "trigger"))]

    result =
      case Map.get(request, "workspace_path") do
        workspace when is_binary(workspace) -> ControlPlane.compile_runtime_task(issue, workspace, opts)
        _ -> {:error, :workspace_path_required}
      end

    case result do
      {:ok, %{} = contract} ->
        Map.merge(identity, %{"ok" => true, "operation" => "construct_task", "contract" => Map.from_struct(contract)})

      {:ok, nil} ->
        Map.merge(identity, %{"ok" => false, "operation" => "construct_task", "error" => "project_binding_required"})

      {:error, reason} ->
        Map.merge(identity, %{"ok" => false, "operation" => "construct_task", "error" => inspect(reason)})
    end
  end

  defp issue_identifier(%{"issue" => issue}) when is_integer(issue), do: "SYMPHONY-#{issue}"
  defp issue_identifier(_request), do: nil

  defp runtime_role("verification_assessment"), do: :independent_review
  defp runtime_role("integration_closeout"), do: :landing
  defp runtime_role("response_recovery"), do: :recovery
  defp runtime_role("planning_coordination"), do: :programme
  defp runtime_role("execution_production"), do: :implementation
  defp runtime_role(value) when value in ~w(implementation independent_review landing recovery programme), do: String.to_atom(value)
  defp runtime_role(_), do: :implementation

  defp runtime_trigger("integration_design"), do: :integration_design
  defp runtime_trigger("repository_wide_judgment"), do: :repository_wide_judgment
  defp runtime_trigger("recovery"), do: :recovery
  defp runtime_trigger(_), do: :bounded

  defp identity_echo(request) do
    %{
      "operation" => Map.get(request, "operation"),
      "repository" => Map.get(request, "repository"),
      "project_id" => Map.get(request, "project_id"),
      "fence" => Map.get(request, "fence"),
      "task_id" => Map.get(request, "task_id"),
      "head_sha" => Map.get(request, "head_sha", Map.get(request, "expected_sha")),
      "workspace_path" => Map.get(request, "workspace_path"),
      "issue_identifier" => Map.get(request, "issue_identifier", issue_identifier(request))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
