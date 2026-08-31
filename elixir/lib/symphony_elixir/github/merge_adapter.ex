defmodule SymphonyElixir.GitHub.MergeAdapter do
  @moduledoc """
  Additive, expected-head merge adapter for GitHub pull requests.

  GitHub remains the authority for branch protection and mergeability. This
  module only supplies a typed, reviewed intent to GitHub's merge endpoint and
  records the attempt in Symphony's durable action ledger.
  """

  require Logger

  alias SymphonyElixir.ActionLedger
  alias SymphonyElixir.GitHub.Client

  defmodule Intent do
    @moduledoc "Reviewed merge request; all revision fields are immutable."
    @enforce_keys [:repository, :pull_number, :reviewed_head, :reviewed_base, :required_checks, :purpose]
    defstruct [
      :repository,
      :pull_number,
      :reviewed_head,
      :reviewed_base,
      :required_checks,
      :purpose,
      merge_method: "squash",
      intent_key: nil
    ]

    @type t :: %__MODULE__{
            repository: String.t(),
            pull_number: pos_integer(),
            reviewed_head: String.t(),
            reviewed_base: String.t(),
            required_checks: [String.t()],
            purpose: String.t(),
            merge_method: String.t(),
            intent_key: String.t() | nil
          }
  end

  @merge_methods ~w(merge squash rebase)

  @type result ::
          {:ok, :merged | :already_satisfied | :duplicate_in_flight, map()}
          | {:error, term()}

  @spec merge(Intent.t(), keyword()) :: result()
  def merge(%Intent{} = intent, opts \\ []) do
    with :ok <- validate_intent(intent),
         {:ok, action, plan_state} <- plan_action(intent, opts),
         {:ok, result} <- execute_if_needed(action, plan_state, intent, opts) do
      result
    end
  end

  @spec validate_intent(Intent.t()) :: :ok | {:error, term()}
  def validate_intent(%Intent{} = intent) do
    cond do
      not valid_repo?(intent.repository) ->
        {:error, :invalid_repository}

      not is_integer(intent.pull_number) or intent.pull_number < 1 ->
        {:error, :invalid_pull_number}

      not valid_sha?(intent.reviewed_head) ->
        {:error, :invalid_reviewed_head}

      not valid_sha?(intent.reviewed_base) ->
        {:error, :invalid_reviewed_base}

      not is_list(intent.required_checks) or not Enum.all?(intent.required_checks, &valid_text?/1) ->
        {:error, :invalid_required_checks}

      not valid_text?(intent.purpose) ->
        {:error, :invalid_purpose}

      intent.merge_method not in @merge_methods ->
        {:error, :invalid_merge_method}

      intent.intent_key != nil and not valid_text?(intent.intent_key) ->
        {:error, :invalid_intent_key}

      true ->
        :ok
    end
  end

  defp plan_action(intent, opts) do
    ledger = Keyword.get(opts, :ledger, ActionLedger)
    key = intent.intent_key || intent_key(intent)

    ledger_intent = %{
      kind: :merge,
      source: %{
        "repository" => intent.repository,
        "revision" => intent.reviewed_head
      },
      target: %{
        "type" => "github_pull_request",
        "id" => "#{intent.repository}##{intent.pull_number}"
      },
      purpose: intent.purpose,
      checkpoint: "reviewed-head-#{intent.reviewed_head}-base-#{intent.reviewed_base}",
      expected_postcondition: "pull_request_merged",
      policy_fingerprint:
        ActionLedger.policy_fingerprint(%{
          repository: intent.repository,
          base: intent.reviewed_base,
          checks: intent.required_checks,
          method: intent.merge_method
        }),
      idempotency_key: key
    }

    case ActionLedger.plan(ledger, ledger_intent) do
      {:ok, action, state} -> {:ok, action, state}
      {:error, reason} -> {:error, {:merge_ledger_plan_failed, reason}}
    end
  end

  defp execute_if_needed(%ActionLedger.Action{state: state} = action, :existing, _intent, _opts)
       when state in [:succeeded, :already_satisfied],
       do: {:ok, {:ok, :already_satisfied, %{action_id: action.id, disposition: "duplicate_suppressed"}}}

  defp execute_if_needed(%ActionLedger.Action{} = action, :existing, _intent, _opts),
    do: {:ok, {:error, {:duplicate_in_flight, action.id}}}

  defp execute_if_needed(action, :new, intent, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Client.request/5)
    request_opts = Keyword.take(opts, [:tracker_settings])
    telemetry = Keyword.get(opts, :telemetry_fun, &:telemetry.execute/3)
    router = Keyword.get(opts, :review_router, fn _reason -> :ok end)

    with {:ok, current} <- read_pull(request_fun, request_opts, intent),
         :ok <- verify_reviewed_revisions(current, intent) do
      if current["merged"] == true do
        transition!(action, :already_satisfied, %{"disposition" => "already_merged", "revision" => intent.reviewed_head}, opts)
        emit(telemetry, :already_satisfied, intent)
        {:ok, {:ok, :already_satisfied, %{pull_number: intent.pull_number, disposition: "already_merged"}}}
      else
        submit_reviewed_merge(action, intent, request_fun, request_opts, telemetry, router, opts)
      end
    else
      {:error, :stale_source} = error -> stale(action, intent, router, error, opts)
      {:error, {:checks_failed, _} = reason} = error -> fail(action, :needs_input, reason, opts, error)
      {:error, {:github_api_status, 409}} = error -> stale(action, intent, router, error, opts)
      {:error, reason} = error -> fail(action, :terminal_failure, reason, opts, error)
    end
  end

  defp submit_reviewed_merge(action, intent, request_fun, request_opts, telemetry, router, opts) do
    with {:ok, checks} <- read_checks(request_fun, request_opts, intent),
         :ok <- verify_checks(checks, intent.required_checks),
         {:ok, _} <- transition(action, :dispatched, %{"disposition" => "expected_head_merge_submitted"}, opts),
         {:ok, response} <- submit_merge(request_fun, request_opts, intent),
         {:ok, outcome} <- verify_merge_response(response, intent) do
      transition!(action, :succeeded, %{"revision" => intent.reviewed_head, "disposition" => outcome}, opts)
      emit(telemetry, :merged, intent)
      {:ok, {:ok, :merged, %{pull_number: intent.pull_number, disposition: outcome}}}
    else
      {:error, {:checks_failed, _} = reason} = error -> fail(action, :needs_input, reason, opts, error)
      {:error, {:github_api_status, 409}} = error -> stale(action, intent, router, error, opts)
      {:error, reason} = error -> fail(action, :terminal_failure, reason, opts, error)
    end
  end

  defp read_pull(fun, opts, intent) do
    path = "/repos/#{repo_path(intent.repository)}/pulls/#{intent.pull_number}"

    case fun.("GET", path, %{}, nil, opts) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_checks(_fun, _opts, %{required_checks: []}), do: {:ok, []}

  defp read_checks(fun, opts, intent) do
    path = "/repos/#{repo_path(intent.repository)}/commits/#{intent.reviewed_head}/check-runs"

    case fun.("GET", path, %{"per_page" => 100}, nil, opts) do
      {:ok, %{status: 200, body: %{"check_runs" => checks}}} when is_list(checks) -> {:ok, checks}
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit_merge(fun, opts, intent) do
    path = "/repos/#{repo_path(intent.repository)}/pulls/#{intent.pull_number}/merge"
    body = %{"sha" => intent.reviewed_head, "merge_method" => intent.merge_method}

    case fun.("PUT", path, %{}, body, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_reviewed_revisions(current, intent) do
    head = get_in(current, ["head", "sha"])
    base = get_in(current, ["base", "sha"])
    if head == intent.reviewed_head and base == intent.reviewed_base, do: :ok, else: {:error, :stale_source}
  end

  defp verify_checks(checks, required) do
    names = MapSet.new(checks, &get_in(&1, ["name"]))
    failed = Enum.filter(checks, &(get_in(&1, ["conclusion"]) not in ["success", "skipped", "neutral"]))
    missing = Enum.reject(required, &MapSet.member?(names, &1))
    if failed == [] and missing == [], do: :ok, else: {:error, {:checks_failed, missing}}
  end

  defp verify_merge_response(%{"merged" => true}, _intent), do: {:ok, "merged"}
  defp verify_merge_response(%{"message" => message}, _intent) when is_binary(message), do: {:error, {:merge_rejected, message}}
  defp verify_merge_response(_, _intent), do: {:error, :merge_postcondition_unverified}

  defp stale(action, _intent, router, _error, opts) do
    _ = router.(:stale_source)
    fail(action, :needs_input, :stale_source, opts, :stale_source, %{"disposition" => "fresh_review_required"})
  end

  defp fail(action, state, reason, opts, original, extra \\ %{}) do
    effect = Map.merge(%{"disposition" => "merge_failed", "workspace_key" => safe_reason(reason)}, extra)
    _ = transition(action, state, effect, opts)
    {:ok, {:error, original}}
  end

  defp transition(action, state, effect, opts) do
    ledger = Keyword.get(opts, :ledger, ActionLedger)
    ActionLedger.transition(ledger, action.id, state, effect)
  end

  defp transition!(action, state, effect, opts), do: _ = transition(action, state, effect, opts)

  defp emit(fun, outcome, intent) do
    fun.([:symphony, :github, :merge], %{count: 1}, %{outcome: outcome, repository: intent.repository, pull_number: intent.pull_number})
  rescue
    _ -> :ok
  end

  defp intent_key(intent), do: "merge:" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(intent)), case: :lower)
  defp valid_repo?(repo), do: is_binary(repo) and String.match?(repo, ~r/^[^\s\/]+\/[^\s\/]+$/)
  defp valid_sha?(sha), do: is_binary(sha) and String.match?(sha, ~r/^[0-9a-fA-F]{40}$/)
  defp valid_text?(value), do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 512

  defp repo_path(repo) do
    repo |> String.split("/", parts: 2) |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp safe_reason({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_), do: "provider_error"
end
