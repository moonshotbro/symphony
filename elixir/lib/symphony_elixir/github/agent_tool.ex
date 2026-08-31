defmodule SymphonyElixir.GitHub.AgentTool do
  @moduledoc """
  Provider-native GitHub REST tool exposed to Codex app-server turns.
  """

  alias SymphonyElixir.GitHub.{Client, MergeAdapter}

  @github_api_tool "github_api"
  @github_merge_tool "github_merge"
  # Generic REST access is deliberately read-only.  All mutations, including
  # merges, must use a typed adapter with ledger, scope, and expected-head
  # guards; otherwise this tool would provide a policy bypass.
  @allowed_methods ["GET"]
  @github_api_description """
  Execute a GitHub REST API request using Symphony's configured auth.
  """
  @github_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => @allowed_methods,
        "description" => "Read-only GitHub REST method. Mutations use typed governed tools."
      },
      "path" => %{
        "type" => "string",
        "description" => "GitHub REST path such as /repos/owner/repo/issues/1/comments."
      },
      "params" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "description" => "Optional JSON request body."
      }
    }
  }
  @github_merge_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["repository", "pull_number", "reviewed_head", "reviewed_base", "required_checks", "purpose", "review_evidence"],
    "properties" => %{
      "repository" => %{"type" => "string"},
      "pull_number" => %{"type" => "integer", "minimum" => 1},
      "reviewed_head" => %{"type" => "string"},
      "reviewed_base" => %{"type" => "string"},
      "required_checks" => %{"type" => "array", "items" => %{"type" => "string"}},
      "purpose" => %{"type" => "string"},
      "merge_method" => %{"type" => "string", "enum" => ["merge", "squash", "rebase"]},
      "review_evidence" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["source", "reviewer", "reviewed_at", "head", "base", "checks"],
        "properties" => %{
          "source" => %{"type" => "string"},
          "reviewer" => %{"type" => "string"},
          "reviewed_at" => %{"type" => "string"},
          "head" => %{"type" => "string"},
          "base" => %{"type" => "string"},
          "checks" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @github_api_tool -> execute_github_api(arguments, opts)
      @github_merge_tool -> execute_github_merge(arguments, opts)
      other -> unsupported_tool_response(other)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @github_api_tool,
        "description" => @github_api_description,
        "inputSchema" => @github_api_input_schema
      },
      %{
        "name" => @github_merge_tool,
        "description" => "Merge a reviewed GitHub pull request through Symphony's durable expected-head guard. GitHub branch protection remains authoritative.",
        "inputSchema" => @github_merge_input_schema
      }
    ]
  end

  defp execute_github_merge(arguments, opts) do
    case merge_intent(arguments) do
      {:ok, intent} ->
        merge_opts = Keyword.take(opts, [:tracker_settings, :ledger, :request_fun, :recovery_fun, :telemetry_fun, :review_router])

        case MergeAdapter.merge(intent, merge_opts) do
          {:ok, outcome, details} -> dynamic_tool_response(true, encode_payload(%{"outcome" => outcome, "details" => details}))
          {:error, reason} -> failure_response(tool_error_payload({:github_merge, reason}))
        end

      {:error, reason} ->
        failure_response(tool_error_payload({:github_merge, reason}))
    end
  end

  defp merge_intent(arguments) when is_map(arguments) do
    with {:ok, evidence} <- merge_evidence(Map.get(arguments, "review_evidence")),
         {:ok, pull_number} <- positive_integer(Map.get(arguments, "pull_number")),
         {:ok, required_checks} <- text_list(Map.get(arguments, "required_checks")),
         {:ok, merge_method} <- optional_merge_method(Map.get(arguments, "merge_method")) do
      {:ok,
       %MergeAdapter.Intent{
         repository: Map.get(arguments, "repository"),
         pull_number: pull_number,
         reviewed_head: Map.get(arguments, "reviewed_head"),
         reviewed_base: Map.get(arguments, "reviewed_base"),
         required_checks: required_checks,
         purpose: Map.get(arguments, "purpose"),
         merge_method: merge_method,
         review_evidence: evidence
       }}
    end
  end

  defp merge_intent(_arguments), do: {:error, :invalid_arguments}

  defp merge_evidence(%{} = evidence) do
    with {:ok, checks} <- text_list(Map.get(evidence, "checks")) do
      {:ok,
       %MergeAdapter.ReviewEvidence{
         source: Map.get(evidence, "source"),
         reviewer: Map.get(evidence, "reviewer"),
         reviewed_at: Map.get(evidence, "reviewed_at"),
         head: Map.get(evidence, "head"),
         base: Map.get(evidence, "base"),
         checks: checks
       }}
    end
  end

  defp merge_evidence(_evidence), do: {:error, :invalid_review_evidence}
  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_pull_number}

  defp text_list(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: {:error, :invalid_required_checks}
  end

  defp text_list(_values), do: {:error, :invalid_required_checks}
  defp optional_merge_method(nil), do: {:ok, "squash"}
  defp optional_merge_method(value) when value in ["merge", "squash", "rebase"], do: {:ok, value}
  defp optional_merge_method(_value), do: {:error, :invalid_merge_method}

  defp execute_github_api(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with {:ok, method, path, params, body} <- normalize_arguments(arguments),
         {:ok, %{status: status, body: response_body}} <-
           github_client.(method, path, params, body, client_opts),
         true <- is_integer(status) do
      rest_response(status, response_body)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:github_unknown_payload))
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_method(Map.get(arguments, "method")),
         {:ok, path} <- normalize_path(Map.get(arguments, "path")),
         {:ok, params} <- normalize_params(Map.get(arguments, "params")) do
      {:ok, method, path, params, Map.get(arguments, "body")}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_method(method) when is_binary(method) do
    normalized = method |> String.trim() |> String.upcase()
    if normalized in @allowed_methods, do: {:ok, normalized}, else: {:error, :invalid_method}
  end

  defp normalize_method(_method), do: {:error, :invalid_method}

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    if String.starts_with?(trimmed, "/") and not String.contains?(trimmed, ["://", "\n", "\r", <<0>>]) do
      {:ok, trimmed}
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp normalize_params(nil), do: {:ok, %{}}
  defp normalize_params(params) when is_map(params), do: {:ok, params}
  defp normalize_params(_params), do: {:error, :invalid_params}

  defp rest_response(status, body) do
    dynamic_tool_response(status in 200..299, encode_payload(%{"status" => status, "body" => body}))
  end

  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, output} -> output
      {:error, _reason} -> inspect(payload)
    end
  end

  defp unsupported_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`github_api` expects an object with `method` and `path`."}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "`github_api.method` must be GET. Mutations use typed governed tools."}}
  end

  defp tool_error_payload(:invalid_path) do
    %{"error" => %{"message" => "`github_api.path` must be a relative GitHub REST path."}}
  end

  defp tool_error_payload(:invalid_params) do
    %{"error" => %{"message" => "`github_api.params` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_github_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.provider.token` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:github_merge, reason}) do
    %{"error" => %{"message" => "GitHub merge was not completed.", "reason" => inspect(reason)}}
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "GitHub API tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
