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

  defmodule ReviewEvidence do
    @moduledoc "Privacy-bounded evidence for the exact reviewed pull-request head."
    @enforce_keys [:source, :reviewer, :reviewed_at, :head, :base, :checks]
    defstruct [:source, :reviewer, :reviewed_at, :head, :base, :checks]

    @type t :: %__MODULE__{
            source: String.t(),
            reviewer: String.t(),
            reviewed_at: String.t(),
            head: String.t(),
            base: String.t(),
            checks: [String.t()]
          }
  end

  defmodule Intent do
    @moduledoc "Reviewed merge request; all revision fields are immutable."
    @enforce_keys [
      :repository,
      :pull_number,
      :reviewed_head,
      :reviewed_base,
      :required_checks,
      :purpose,
      :review_evidence
    ]
    defstruct [
      :repository,
      :pull_number,
      :reviewed_head,
      :reviewed_base,
      :required_checks,
      :purpose,
      :review_evidence,
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
            review_evidence: ReviewEvidence.t(),
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
         :ok <- validate_configured_repository(intent, opts),
         {:ok, action, plan_state} <- plan_action(intent, opts),
         {:ok, result} <- execute_if_needed(action, plan_state, intent, opts) do
      result
    end
  end

  @spec validate_intent(Intent.t()) :: :ok | {:error, term()}
  def validate_intent(%Intent{} = intent) do
    with :ok <- validate_repository(intent.repository),
         :ok <- validate_pull_number(intent.pull_number),
         :ok <- validate_sha(intent.reviewed_head, :invalid_reviewed_head),
         :ok <- validate_sha(intent.reviewed_base, :invalid_reviewed_base),
         :ok <- validate_required_checks(intent.required_checks),
         :ok <- validate_purpose(intent.purpose),
         :ok <- validate_evidence(intent.review_evidence, intent),
         :ok <- validate_merge_method(intent.merge_method) do
      validate_intent_key(intent.intent_key)
    end
  end

  defp validate_repository(value), do: if(valid_repo?(value), do: :ok, else: {:error, :invalid_repository})
  defp validate_pull_number(value), do: if(is_integer(value) and value > 0, do: :ok, else: {:error, :invalid_pull_number})
  defp validate_sha(value, error), do: if(valid_sha?(value), do: :ok, else: {:error, error})
  defp validate_required_checks(value), do: if(is_list(value) and Enum.all?(value, &valid_text?/1), do: :ok, else: {:error, :invalid_required_checks})
  defp validate_purpose(value), do: if(valid_text?(value), do: :ok, else: {:error, :invalid_purpose})
  defp validate_evidence(value, intent), do: if(valid_review_evidence?(value, intent), do: :ok, else: {:error, :invalid_review_evidence})
  defp validate_merge_method(value), do: if(value in @merge_methods, do: :ok, else: {:error, :invalid_merge_method})
  defp validate_intent_key(nil), do: :ok
  defp validate_intent_key(value), do: if(valid_text?(value), do: :ok, else: {:error, :invalid_intent_key})

  @spec review_fingerprint(ReviewEvidence.t()) :: String.t()
  def review_fingerprint(%ReviewEvidence{} = evidence) do
    ActionLedger.policy_fingerprint({
      evidence.source,
      evidence.reviewer,
      evidence.reviewed_at,
      evidence.head,
      evidence.base,
      evidence.checks
    })
  end

  defp validate_configured_repository(intent, opts) do
    tracker_settings = Keyword.get(opts, :tracker_settings)

    case Client.configured_repository(tracker_settings) do
      {:ok, repository} when repository == intent.repository -> :ok
      {:ok, _repository} -> {:error, :repository_scope_mismatch}
      {:error, reason} -> {:error, {:repository_scope_unavailable, reason}}
    end
  end

  @spec plan_action(Intent.t(), keyword()) ::
          {:ok, ActionLedger.Action.t(), :new | :existing} | {:error, term()}
  defp plan_action(intent, opts) do
    ledger = ledger_server(opts)

    key = intent.intent_key || intent_key(intent)

    ledger_intent = %{
      kind: :merge,
      source: %{
        "repository" => intent.repository,
        "revision" => intent.reviewed_head,
        "review_source" => intent.review_evidence.source,
        "reviewer" => intent.review_evidence.reviewer,
        "review_fingerprint" => review_fingerprint(intent.review_evidence),
        "review_checks" => Jason.encode!(intent.review_evidence.checks)
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

  @spec ledger_server(keyword()) :: GenServer.server()
  defp ledger_server(opts) do
    case Keyword.get(opts, :ledger, ActionLedger) do
      ledger when is_pid(ledger) -> ledger
      ledger when is_atom(ledger) -> ledger
      {name, node} when is_atom(name) and is_atom(node) -> {name, node}
      _invalid -> ActionLedger
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
         {:ok, _} <- transition(action, :dispatched, %{"disposition" => "expected_head_merge_submitted"}, opts) do
      submit_merge(request_fun, request_opts, intent)
      |> handle_submit_result(action, intent, telemetry, router, request_fun, request_opts, opts)
    else
      {:error, {:checks_failed, _} = reason} = error ->
        fail(action, :needs_input, reason, opts, error)

      {:error, {:github_api_status, 409}} = error ->
        stale(action, intent, router, error, opts)

      {:error, reason} = error ->
        fail(action, :terminal_failure, reason, opts, error)
    end
  end

  defp handle_submit_result({:ok, response}, action, intent, telemetry, _router, _request_fun, _request_opts, opts),
    do: complete_merge_response(action, intent, response, telemetry, opts)

  defp handle_submit_result({:error, {:github_api_status, 409} = reason}, action, intent, _telemetry, router, _request_fun, _request_opts, opts),
    do: stale(action, intent, router, {:error, reason}, opts)

  defp handle_submit_result({:error, reason}, action, intent, _telemetry, _router, request_fun, request_opts, opts) do
    if uncertain_provider_error?(reason) do
      reconcile_uncertain(action, intent, request_fun, request_opts, reason, opts)
    else
      fail(action, :terminal_failure, reason, opts, {:error, reason})
    end
  end

  defp complete_merge_response(action, intent, response, telemetry, opts) do
    case verify_merge_response(response, intent) do
      {:ok, outcome} ->
        transition!(action, :succeeded, %{"revision" => intent.reviewed_head, "disposition" => outcome}, opts)
        emit(telemetry, :merged, intent)
        {:ok, {:ok, :merged, %{pull_number: intent.pull_number, disposition: outcome}}}

      {:error, reason} ->
        fail(action, :terminal_failure, reason, opts, {:error, reason})
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

  defp uncertain_provider_error?({:github_api_request, _}), do: true
  defp uncertain_provider_error?({:github_api_status, status}) when status >= 500, do: true
  defp uncertain_provider_error?(_), do: false

  defp reconcile_uncertain(action, intent, request_fun, request_opts, reason, opts) do
    _ = transition(action, :uncertain, %{"disposition" => "postcondition_reconciliation_required"}, opts)
    recovery_fun = Keyword.get(opts, :recovery_fun, fn -> recover_merge(request_fun, request_opts, intent) end)

    case recovery_fun.() do
      {:ok, evidence} ->
        inspected = ActionLedger.inspect_recovered(Keyword.get(opts, :ledger, ActionLedger), action.id, evidence)

        case inspected do
          {:ok, _updated, :already_satisfied} ->
            {:ok, {:ok, :already_satisfied, %{pull_number: intent.pull_number, disposition: "recovered_after_uncertain_merge"}}}

          {:ok, _updated, :retryable_failure} ->
            {:ok, {:error, reason}}

          {:ok, _updated, :quarantined} ->
            {:ok, {:error, reason}}

          {:error, _reason} ->
            {:ok, {:error, reason}}
        end

      {:error, _reason} ->
        {:ok, {:error, reason}}
    end
  end

  defp recover_merge(fun, opts, intent) do
    case read_pull(fun, opts, intent) do
      {:ok, current} ->
        case verify_reviewed_revisions(current, intent) do
          :ok ->
            {:ok,
             %{
               provider: "github",
               authoritative: true,
               exists: current["merged"] == true,
               revision: intent.reviewed_head,
               disposition: if(current["merged"] == true, do: "provider_postcondition_confirmed", else: "postcondition_absent")
             }}

          {:error, :stale_source} ->
            # A merged PR at a different head/base is not evidence that this
            # reviewed action happened.  Mark the inspection non-authoritative
            # so the ledger quarantines the uncertain action rather than
            # silently settling it as already satisfied.
            {:ok,
             %{
               provider: "github",
               authoritative: false,
               exists: false,
               disposition: "reviewed_revision_mismatch"
             }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

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
    metadata = %{outcome: outcome, repository: intent.repository, pull_number: intent.pull_number}
    fun.([:symphony, :github, :merge], %{count: 1}, metadata)
  rescue
    _ -> :ok
  end

  defp intent_key(intent), do: "merge:" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(intent)), case: :lower)
  defp valid_repo?(repo), do: is_binary(repo) and String.match?(repo, ~r/^[^\s\/]+\/[^\s\/]+$/)
  defp valid_sha?(sha), do: is_binary(sha) and String.match?(sha, ~r/^[0-9a-fA-F]{40}$/)
  defp valid_text?(value), do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 512

  defp valid_review_evidence?(%ReviewEvidence{} = evidence, intent) do
    valid_source?(evidence.source, intent) and valid_reviewer?(evidence.reviewer) and
      valid_timestamp?(evidence.reviewed_at) and valid_revision_evidence?(evidence, intent) and
      valid_check_evidence?(evidence.checks, intent.required_checks)
  end

  defp valid_review_evidence?(_, _intent), do: false
  defp valid_source?(value, intent), do: valid_text?(value) and source_matches_intent?(value, intent)

  defp source_matches_intent?(source, intent) do
    case Regex.run(~r/^github:([^\s\/]+\/[^\s\/]+)#([1-9][0-9]*)$/, source, capture: :all_but_first) do
      [repository, number] -> repository == intent.repository and number == Integer.to_string(intent.pull_number)
      _ -> false
    end
  end

  defp valid_reviewer?(value), do: valid_text?(value) and Regex.match?(~r/^[A-Za-z0-9_.-]{1,100}$/, value)
  defp valid_revision_evidence?(evidence, intent), do: evidence.head == intent.reviewed_head and evidence.base == intent.reviewed_base
  defp valid_check_evidence?(checks, required) when is_list(checks), do: Enum.all?(checks, &valid_text?/1) and Enum.sort(Enum.uniq(checks)) == Enum.sort(Enum.uniq(required))
  defp valid_check_evidence?(_, _), do: false
  defp valid_timestamp?(value) when is_binary(value), do: match?({:ok, _, 0}, DateTime.from_iso8601(value))
  defp valid_timestamp?(_value), do: false

  defp repo_path(repo) do
    repo |> String.split("/", parts: 2) |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp safe_reason({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_), do: "provider_error"
end
