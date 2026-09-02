defmodule SymphonyElixir.ActionLedger do
  @moduledoc """
  Durable, privacy-bounded intent/effect ledger for mutating coordination.

  The ledger serializes records through one GenServer and persists complete
  action snapshots as newline-delimited JSON. A record is appended and synced
  before its transition becomes visible to callers. Malformed or truncated
  storage fails startup closed.
  """

  use GenServer
  require Logger

  @schema "symphony.action-ledger.v1"
  @kinds ~w(task_creation task_messaging automation fork handoff merge)a
  @states ~w(planned preflight_rejected dispatched succeeded already_satisfied uncertain retryable_failure compensated quarantined needs_input terminal_failure)a
  @terminal_states ~w(preflight_rejected succeeded already_satisfied compensated terminal_failure)a
  @source_keys ~w(goal_id task_id issue_id issue_identifier repository revision native_project_id session_id correlation_id fence attempt review_source reviewer review_fingerprint review_checks)
  @target_keys ~w(type id host project worker_host)
  @effect_keys ~w(thread_id turn_id automation_id fork_thread_id destination_thread_id worktree_id revision session_id session_correlation_id worker_host host_assertion disposition workspace_key)
  @inspection_keys ~w(provider authoritative exists session_id session_correlation_id workspace_key revision disposition)
  @identity_keys ~w(goal_id task_id issue_id issue_identifier repository revision native_project_id session_id correlation_id fence attempt)
  @target_identity_keys ~w(type id host project worker_host)
  @effect_identity_keys ~w(thread_id turn_id automation_id fork_thread_id destination_thread_id worktree_id revision session_id session_correlation_id worker_host workspace_key)
  @forbidden_key_fragments ~w(prompt secret token password body content credential)
  @blocker_classifications ~w(goal.stalled)

  @transitions %{
    planned: ~w(preflight_rejected dispatched quarantined needs_input terminal_failure)a,
    dispatched: ~w(succeeded already_satisfied uncertain retryable_failure compensated quarantined needs_input terminal_failure)a,
    uncertain: ~w(succeeded already_satisfied retryable_failure compensated quarantined needs_input terminal_failure)a,
    retryable_failure: ~w(planned quarantined needs_input terminal_failure)a,
    quarantined: ~w(planned needs_input terminal_failure)a,
    needs_input: ~w(planned already_satisfied quarantined terminal_failure)a
  }

  defmodule Action do
    @moduledoc "A single normalized coordination action."

    @enforce_keys [
      :id,
      :idempotency_key,
      :lineage_key,
      :kind,
      :source,
      :target,
      :purpose_hash,
      :checkpoint,
      :expected_postcondition,
      :policy_fingerprint,
      :state,
      :inserted_at,
      :updated_at
    ]
    defstruct [
      :id,
      :idempotency_key,
      :lineage_key,
      :kind,
      :source,
      :target,
      :purpose_hash,
      :checkpoint,
      :expected_postcondition,
      :policy_fingerprint,
      :state,
      :inserted_at,
      :updated_at,
      :supersedes,
      :blocker_classification,
      :resume_condition,
      :valid_until,
      observed_effect: %{}
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            idempotency_key: String.t(),
            lineage_key: String.t(),
            kind: atom(),
            source: map(),
            target: map(),
            purpose_hash: String.t(),
            checkpoint: String.t(),
            expected_postcondition: String.t(),
            policy_fingerprint: String.t(),
            state: atom(),
            inserted_at: String.t(),
            updated_at: String.t(),
            supersedes: String.t() | nil,
            blocker_classification: String.t() | nil,
            resume_condition: String.t() | nil,
            valid_until: String.t() | nil,
            observed_effect: map()
          }
  end

  @type intent :: %{
          required(:kind) => atom() | String.t(),
          required(:source) => map(),
          required(:target) => map(),
          required(:purpose) => String.t(),
          required(:checkpoint) => String.t(),
          required(:expected_postcondition) => String.t(),
          required(:policy_fingerprint) => String.t(),
          optional(:idempotency_key) => String.t(),
          optional(:blocker_classification) => String.t(),
          optional(:resume_condition) => String.t(),
          optional(:valid_until) => String.t()
        }

  @type reconciliation :: %{
          pending: [Action.t()],
          retryable: [Action.t()],
          quarantined: [Action.t()],
          needs_input: [Action.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec plan(GenServer.server(), intent()) ::
          {:ok, Action.t(), :new | :existing} | {:error, term()}
  def plan(server \\ __MODULE__, intent), do: GenServer.call(server, {:plan, intent})

  @spec transition(GenServer.server(), String.t(), atom(), map()) ::
          {:ok, Action.t()} | {:error, term()}
  def transition(server \\ __MODULE__, action_id, next_state, effect \\ %{}) do
    GenServer.call(server, {:transition, action_id, next_state, effect})
  end

  @spec observe_effect(GenServer.server(), String.t(), map()) ::
          {:ok, Action.t()} | {:error, term()}
  def observe_effect(server \\ __MODULE__, action_id, effect) do
    GenServer.call(server, {:observe_effect, action_id, effect})
  end

  @spec get(GenServer.server(), String.t()) :: {:ok, Action.t()} | :error
  def get(server \\ __MODULE__, action_id), do: GenServer.call(server, {:get, action_id})

  @spec reconcile(GenServer.server()) :: reconciliation()
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile)

  @doc """
  Inspect an uncertain action against authoritative provider evidence.

  Evidence is validated and read before the resulting transition is persisted,
  preventing a recovered dispatch from being retried blindly.
  """
  @spec inspect_recovered(GenServer.server(), String.t(), map()) ::
          {:ok, Action.t(), :already_satisfied | :retryable_failure | :quarantined}
          | {:error, term()}
  def inspect_recovered(server \\ __MODULE__, action_id, evidence) do
    GenServer.call(server, {:inspect_recovered, action_id, evidence})
  end

  @doc "Read-only inspection of a ledger path; never repairs or truncates it."
  @spec inspect_storage(Path.t()) :: {:ok, map()} | {:error, term()}
  def inspect_storage(path) do
    with :ok <- validate_path(path),
         {:ok, actions, order} <- load(path) do
      action_list = Enum.map(order, &Map.fetch!(actions, &1))

      {:ok,
       %{
         schema: @schema,
         path: path,
         action_count: length(action_list),
         actions: action_list,
         reconciliation: reconcile_actions(action_list)
       }}
    end
  end

  @spec enabled?(GenServer.server()) :: boolean()
  def enabled?(server \\ __MODULE__), do: GenServer.call(server, :enabled?)

  @spec resume_goal(GenServer.server(), String.t(), String.t()) ::
          {:ok, Action.t()} | {:error, term()}
  def resume_goal(server \\ __MODULE__, action_id, condition) do
    GenServer.call(server, {:resume_goal, action_id, condition})
  end

  @spec policy_fingerprint(term()) :: String.t()
  def policy_fingerprint(policy), do: hash(policy)

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)
    path = Keyword.fetch!(opts, :path)

    with :ok <- validate_path(path),
         {:ok, actions, order} <- load(path),
         {:ok, actions, order} <- recover_dispatched(path, actions, order) do
      {:ok, %{enabled: enabled, path: path, actions: actions, order: order}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:plan, _intent}, _from, %{enabled: false} = state) do
    {:reply, {:error, :action_ledger_disabled}, state}
  end

  def handle_call({:plan, intent}, _from, state) do
    case normalize_intent(intent) do
      {:ok, normalized} -> plan_normalized(state, normalized)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:transition, action_id, next_state, effect}, _from, state) do
    with %Action{} = action <- Map.get(state.actions, action_id),
         {:ok, normalized_state} <- normalize_state(next_state),
         :ok <- validate_transition(action.state, normalized_state),
         {:ok, normalized_effect} <- normalize_bounded_map(effect, @effect_keys),
         updated <- update_action(action, normalized_state, normalized_effect),
         :ok <- persist(state.path, updated) do
      emit_transition(updated, action.state)
      next = put_action(state, updated)
      {:reply, {:ok, updated}, next}
    else
      nil -> {:reply, {:error, :action_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:observe_effect, action_id, effect}, _from, state) do
    with %Action{} = action <- Map.get(state.actions, action_id),
         false <- action.state in @terminal_states,
         {:ok, normalized_effect} <- normalize_bounded_map(effect, @effect_keys),
         updated <- update_action(action, action.state, normalized_effect),
         :ok <- persist(state.path, updated) do
      emit_transition(updated, action.state)
      next = put_action(state, updated)
      {:reply, {:ok, updated}, next}
    else
      nil -> {:reply, {:error, :action_not_found}, state}
      true -> {:reply, {:error, :terminal_action_immutable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, action_id}, _from, state) do
    reply =
      case Map.fetch(state.actions, action_id) do
        {:ok, action} -> {:ok, action}
        :error -> :error
      end

    {:reply, reply, state}
  end

  def handle_call(:reconcile, _from, state) do
    actions = Enum.map(state.order, &Map.fetch!(state.actions, &1))

    reply = reconcile_actions(actions)

    {:reply, reply, state}
  end

  def handle_call({:inspect_recovered, action_id, evidence}, _from, state) do
    with %Action{state: :uncertain} = action <- Map.get(state.actions, action_id),
         {:ok, normalized} <- normalize_inspection(evidence),
         {:ok, next_state, effect} <- settle_inspected_action(action, normalized),
         :ok <- validate_transition(action.state, next_state),
         {:ok, normalized_effect} <- normalize_bounded_map(effect, @effect_keys),
         updated <- update_action(action, next_state, normalized_effect),
         :ok <- persist(state.path, updated) do
      emit_transition(updated, action.state)
      {:reply, {:ok, updated, next_state}, put_action(state, updated)}
    else
      nil -> {:reply, {:error, :action_not_found}, state}
      %Action{} -> {:reply, {:error, :action_not_uncertain}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume_goal, action_id, condition}, _from, state) do
    with %Action{state: :needs_input, blocker_classification: "goal.stalled"} = action <-
           Map.get(state.actions, action_id),
         true <- action.resume_condition == condition,
         updated <- update_action(action, :already_satisfied, %{"disposition" => "goal_resumed"}),
         :ok <- persist(state.path, updated) do
      emit_transition(updated, action.state)
      {:reply, {:ok, updated}, put_action(state, updated)}
    else
      nil -> {:reply, {:error, :action_not_found}, state}
      %Action{} -> {:reply, {:error, :action_not_stalled_goal}, state}
      false -> {:reply, {:error, :resume_condition_mismatch}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:enabled?, _from, state), do: {:reply, state.enabled, state}

  defp plan_normalized(state, normalized) do
    case Map.get(state.actions, normalized.id) do
      %Action{} = existing ->
        {:reply, {:ok, existing, :existing}, state}

      nil ->
        persist_new_action(state, build_action(normalized, state))
    end
  end

  defp persist_new_action(state, action) do
    case persist(state.path, action) do
      :ok ->
        emit_transition(action, nil)
        {:reply, {:ok, action, :new}, put_action(state, action)}

      {:error, reason} ->
        {:reply, {:error, {:ledger_write_failed, reason}}, state}
    end
  end

  defp validate_path(path) when is_binary(path) do
    if String.trim(path) == "", do: {:error, :ledger_path_missing}, else: :ok
  end

  defp validate_path(_path), do: {:error, :ledger_path_invalid}

  defp normalize_intent(intent) when is_map(intent) do
    with {:ok, kind} <- normalize_kind(value(intent, :kind)),
         {:ok, source} <- normalize_bounded_map(value(intent, :source), @source_keys),
         {:ok, target} <- normalize_bounded_map(value(intent, :target), @target_keys),
         {:ok, purpose} <- bounded_string(value(intent, :purpose), :purpose, 512),
         {:ok, checkpoint} <- checkpoint(value(intent, :checkpoint)),
         {:ok, postcondition} <- postcondition(value(intent, :expected_postcondition)),
         {:ok, policy_fingerprint} <- fingerprint(value(intent, :policy_fingerprint)),
         {:ok, blocker_classification, resume_condition} <- stalled_goal_fields(intent),
         {:ok, valid_until} <- optional_timestamp(value(intent, :valid_until)) do
      purpose_hash = hash(purpose)
      lineage_key = hash({kind, source})

      idempotency_key =
        hash({
          kind,
          source,
          target,
          purpose_hash,
          checkpoint,
          postcondition,
          policy_fingerprint,
          blocker_classification,
          resume_condition,
          valid_until
        })

      {:ok,
       %{
         id: "act_" <> String.slice(idempotency_key, 0, 32),
         idempotency_key: idempotency_key,
         lineage_key: lineage_key,
         kind: kind,
         source: source,
         target: target,
         purpose_hash: purpose_hash,
         checkpoint: checkpoint,
         expected_postcondition: postcondition,
         policy_fingerprint: policy_fingerprint,
         blocker_classification: blocker_classification,
         resume_condition: resume_condition,
         valid_until: valid_until
       }}
    end
  end

  defp normalize_intent(_intent), do: {:error, :intent_invalid}

  defp normalize_kind(kind) when is_atom(kind) and kind in @kinds, do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:error, :action_kind_invalid}
      atom -> {:ok, atom}
    end
  end

  defp normalize_kind(_kind), do: {:error, :action_kind_invalid}

  defp normalize_state(state) when is_atom(state) and state in @states, do: {:ok, state}

  defp normalize_state(state) when is_binary(state) do
    case Enum.find(@states, &(Atom.to_string(&1) == state)) do
      nil -> {:error, :action_state_invalid}
      atom -> {:ok, atom}
    end
  end

  defp normalize_state(_state), do: {:error, :action_state_invalid}

  defp normalize_bounded_map(map, allowed_keys) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {raw_key, raw_value}, {:ok, acc} ->
      case normalize_bounded_field(raw_key, raw_value, allowed_keys) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_bounded_map(_map, _allowed_keys), do: {:error, :bounded_map_invalid}

  defp normalize_bounded_field(raw_key, raw_value, allowed_keys) do
    key = to_string(raw_key)

    cond do
      key not in allowed_keys -> {:error, {:field_not_allowed, key}}
      forbidden_key?(key) -> {:error, {:sensitive_field_forbidden, key}}
      key == "host_assertion" -> normalize_host_assertion(raw_value)
      is_nil(raw_value) -> :skip
      not is_binary(raw_value) -> {:error, {:field_value_invalid, key}}
      String.trim(raw_value) == "" -> {:error, {:field_value_invalid, key}}
      byte_size(raw_value) > 256 -> {:error, {:field_value_invalid, key}}
      true -> validate_field_value(key, raw_value)
    end
  end

  # A recovery host assertion is structured evidence, not an arbitrary nested
  # payload. Keep its schema exact so ledger reload remains fail-closed.
  defp normalize_host_assertion(%{"type" => "worker_host", "value" => value} = assertion)
       when map_size(assertion) == 2 do
    case validate_field_value("worker_host", value) do
      {:ok, _key, normalized_value} ->
        {:ok, "host_assertion", %{"type" => "worker_host", "value" => normalized_value}}

      {:error, _reason} ->
        {:error, {:field_value_invalid, "host_assertion"}}
    end
  end

  defp normalize_host_assertion(_assertion), do: {:error, {:field_value_invalid, "host_assertion"}}

  # Identifiers and dispositions are deliberately narrower than arbitrary
  # bounded strings: reject values that could carry credentials or payloads.
  defp validate_field_value(key, value)
       when key in @identity_keys or key in @target_identity_keys or key in @effect_identity_keys or
              key in ["provider", "disposition"] do
    valid? =
      case key do
        "disposition" -> Regex.match?(~r/^[a-z0-9_.:-]{1,128}$/, value)
        "provider" -> Regex.match?(~r/^[a-z0-9_.:-]{1,64}$/, value)
        "repository" -> Regex.match?(~r/^[A-Za-z0-9._:\/@-]{1,256}$/, value)
        _ -> Regex.match?(~r/^[A-Za-z0-9._:@\/#-]{1,256}$/, value)
      end

    if valid?, do: {:ok, key, value}, else: {:error, {:field_value_invalid, key}}
  end

  defp validate_field_value(key, value), do: {:ok, key, value}

  defp bounded_string(value, field, max_bytes) when is_binary(value) do
    if String.trim(value) == "" or byte_size(value) > max_bytes do
      {:error, {field, :invalid}}
    else
      {:ok, value}
    end
  end

  defp bounded_string(_value, field, _max_bytes), do: {:error, {field, :invalid}}

  defp checkpoint(value) do
    with {:ok, string} <- bounded_string(value, :checkpoint, 256),
         true <- Regex.match?(~r/^[A-Za-z0-9._:@\/#-]{1,256}$/, string) do
      {:ok, string}
    else
      _ -> {:error, {:checkpoint, :invalid}}
    end
  end

  defp postcondition(value) do
    with {:ok, string} <- bounded_string(value, :expected_postcondition, 128),
         true <- Regex.match?(~r/^[a-z0-9_.-]+$/, string) do
      {:ok, string}
    else
      _ -> {:error, {:expected_postcondition, :invalid}}
    end
  end

  defp fingerprint(value) when is_binary(value) do
    if hex_hash?(value), do: {:ok, value}, else: {:error, {:policy_fingerprint, :invalid}}
  end

  defp fingerprint(_value), do: {:error, {:policy_fingerprint, :invalid}}

  defp stalled_goal_fields(intent) do
    blocker = value(intent, :blocker_classification)
    resume_condition = value(intent, :resume_condition)

    case {blocker, resume_condition} do
      {nil, nil} ->
        {:ok, nil, nil}

      {blocker, condition} when blocker in @blocker_classifications and is_binary(condition) ->
        case postcondition(condition) do
          {:ok, normalized} -> {:ok, blocker, normalized}
          {:error, _reason} -> {:error, {:resume_condition, :invalid}}
        end

      _ ->
        {:error, {:stalled_goal_fields, :invalid}}
    end
  end

  defp optional_timestamp(nil), do: {:ok, nil}

  defp optional_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> {:ok, value}
      _ -> {:error, {:valid_until, :invalid}}
    end
  end

  defp optional_timestamp(_value), do: {:error, {:valid_until, :invalid}}

  defp forbidden_key?(key) do
    normalized = String.downcase(key)
    Enum.any?(@forbidden_key_fragments, &String.contains?(normalized, &1))
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp hash(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp build_action(normalized, state) do
    timestamp = now()

    %Action{
      id: normalized.id,
      idempotency_key: normalized.idempotency_key,
      lineage_key: normalized.lineage_key,
      kind: normalized.kind,
      source: normalized.source,
      target: normalized.target,
      purpose_hash: normalized.purpose_hash,
      checkpoint: normalized.checkpoint,
      expected_postcondition: normalized.expected_postcondition,
      policy_fingerprint: normalized.policy_fingerprint,
      state: :planned,
      inserted_at: timestamp,
      updated_at: timestamp,
      supersedes: latest_lineage_action_id(state, normalized.lineage_key),
      blocker_classification: normalized.blocker_classification,
      resume_condition: normalized.resume_condition,
      valid_until: normalized.valid_until
    }
  end

  defp latest_lineage_action_id(state, lineage_key) do
    state.order
    |> Enum.reverse()
    |> Enum.find(fn id -> Map.fetch!(state.actions, id).lineage_key == lineage_key end)
  end

  defp validate_transition(state, next_state) do
    if next_state in Map.get(@transitions, state, []) do
      :ok
    else
      {:error, {:invalid_transition, state, next_state}}
    end
  end

  defp update_action(action, next_state, effect) do
    %{action | state: next_state, updated_at: now(), observed_effect: Map.merge(action.observed_effect, effect)}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp put_action(state, action) do
    order = if action.id in state.order, do: state.order, else: state.order ++ [action.id]
    %{state | actions: Map.put(state.actions, action.id, action), order: order}
  end

  defp reconcile_actions(actions) do
    %{
      pending: Enum.filter(actions, &(&1.state in ~w(planned dispatched uncertain)a)),
      retryable: Enum.filter(actions, &(&1.state == :retryable_failure)),
      quarantined: Enum.filter(actions, &(&1.state == :quarantined)),
      needs_input: Enum.filter(actions, &(&1.state == :needs_input))
    }
  end

  defp normalize_inspection(evidence) when is_map(evidence) do
    normalized_input =
      Map.new(evidence, fn {key, value} ->
        value =
          if key in [:authoritative, "authoritative", :exists, "exists"] and is_boolean(value),
            do: Atom.to_string(value),
            else: value

        {key, value}
      end)

    with {:ok, normalized} <- normalize_bounded_map(normalized_input, @inspection_keys),
         true <- normalized["authoritative"] in ["true", "false"],
         true <- normalized["exists"] in ["true", "false"] do
      {:ok, normalized}
    else
      false -> {:error, :inspection_not_authoritative}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_inspection(_evidence), do: {:error, :inspection_invalid}

  defp settle_inspected_action(action, evidence) do
    with true <- evidence["authoritative"] == "true",
         provider when is_binary(provider) <- evidence["provider"] do
      if evidence["exists"] == "true" do
        settle_existing_effect(action, provider, evidence)
      else
        {:ok, :retryable_failure, %{"disposition" => "postcondition_absent"}}
      end
    else
      false -> {:ok, :quarantined, %{"disposition" => "inspection_not_authoritative"}}
      nil -> {:error, {:field_value_invalid, "provider"}}
    end
  end

  defp settle_existing_effect(%Action{expected_postcondition: "codex.session_observed"}, "codex", evidence) do
    with session_id when is_binary(session_id) <- evidence["session_id"],
         workspace_key when is_binary(workspace_key) <- evidence["workspace_key"] do
      {:ok, :already_satisfied,
       %{
         "session_id" => session_id,
         "workspace_key" => workspace_key,
         "disposition" => "provider_postcondition_confirmed"
       }}
    else
      _ -> {:ok, :quarantined, %{"disposition" => "postcondition_evidence_incomplete"}}
    end
  end

  defp settle_existing_effect(%Action{expected_postcondition: "codex.session_observed"}, _provider, _evidence),
    do: {:ok, :quarantined, %{"disposition" => "provider_mismatch"}}

  defp settle_existing_effect(_action, _provider, evidence) do
    {:ok, :already_satisfied, %{"disposition" => evidence["disposition"] || "provider_postcondition_confirmed"}}
  end

  defp persist(path, action) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(encode_action(action)) do
      File.write(path, encoded <> "\n", [:append, :sync])
    end
  end

  defp load(path) do
    case File.read(path) do
      {:ok, ""} -> {:ok, %{}, []}
      {:ok, body} -> decode_events(body)
      {:error, :enoent} -> {:ok, %{}, []}
      {:error, reason} -> {:error, {:ledger_read_failed, reason}}
    end
  end

  defp decode_events(body) do
    lines = String.split(body, "\n", trim: false)

    if List.last(lines) != "" do
      {:error, :ledger_truncated}
    else
      lines
      |> Enum.drop(-1)
      |> Enum.reduce_while({:ok, %{}, []}, &decode_event/2)
    end
  end

  defp decode_event(line, {:ok, actions, order}) do
    with {:ok, raw} <- Jason.decode(line),
         {:ok, action} <- decode_action(raw),
         :ok <- validate_replayed_event(Map.get(actions, action.id), action) do
      next_order = if action.id in order, do: order, else: order ++ [action.id]
      {:cont, {:ok, Map.put(actions, action.id, action), next_order}}
    else
      _ -> {:halt, {:error, :ledger_corrupt}}
    end
  end

  defp validate_replayed_event(nil, %Action{state: :planned}), do: :ok

  defp validate_replayed_event(%Action{} = previous, %Action{} = current) do
    cond do
      previous.idempotency_key != current.idempotency_key -> {:error, :identity_changed}
      previous.state == current.state and previous.state not in @terminal_states -> :ok
      validate_transition(previous.state, current.state) == :ok -> :ok
      true -> {:error, :invalid_replayed_transition}
    end
  end

  defp encode_action(action) do
    %{
      "schema" => @schema,
      "id" => action.id,
      "idempotency_key" => action.idempotency_key,
      "lineage_key" => action.lineage_key,
      "kind" => Atom.to_string(action.kind),
      "source" => action.source,
      "target" => action.target,
      "purpose_hash" => action.purpose_hash,
      "checkpoint" => action.checkpoint,
      "expected_postcondition" => action.expected_postcondition,
      "policy_fingerprint" => action.policy_fingerprint,
      "state" => Atom.to_string(action.state),
      "inserted_at" => action.inserted_at,
      "updated_at" => action.updated_at,
      "supersedes" => action.supersedes,
      "blocker_classification" => action.blocker_classification,
      "resume_condition" => action.resume_condition,
      "valid_until" => action.valid_until,
      "observed_effect" => action.observed_effect
    }
  end

  defp decode_action(%{"schema" => @schema} = raw) do
    with {:ok, kind} <- normalize_kind(raw["kind"]),
         {:ok, state} <- normalize_state(raw["state"]),
         {:ok, source} <- normalize_bounded_map(raw["source"], @source_keys),
         {:ok, target} <- normalize_bounded_map(raw["target"], @target_keys),
         {:ok, effect} <- normalize_bounded_map(raw["observed_effect"], @effect_keys),
         :ok <- validate_encoded_identity(raw, kind, source, target),
         {:ok, blocker_classification, resume_condition} <- stalled_goal_fields(raw),
         {:ok, valid_until} <- optional_timestamp(raw["valid_until"]),
         :ok <- validate_timestamp(raw["inserted_at"]),
         :ok <- validate_timestamp(raw["updated_at"]) do
      {:ok,
       %Action{
         id: raw["id"],
         idempotency_key: raw["idempotency_key"],
         lineage_key: raw["lineage_key"],
         kind: kind,
         source: source,
         target: target,
         purpose_hash: raw["purpose_hash"],
         checkpoint: raw["checkpoint"],
         expected_postcondition: raw["expected_postcondition"],
         policy_fingerprint: raw["policy_fingerprint"],
         state: state,
         inserted_at: raw["inserted_at"],
         updated_at: raw["updated_at"],
         supersedes: raw["supersedes"],
         blocker_classification: blocker_classification,
         resume_condition: resume_condition,
         valid_until: valid_until,
         observed_effect: effect
       }}
    end
  end

  defp decode_action(_raw), do: {:error, :schema_invalid}

  defp validate_encoded_identity(raw, kind, source, target) do
    required_hashes = ~w(idempotency_key lineage_key purpose_hash)

    expected_lineage_key = hash({kind, source})

    expected_idempotency_key =
      hash({
        kind,
        source,
        target,
        raw["purpose_hash"],
        raw["checkpoint"],
        raw["expected_postcondition"],
        raw["policy_fingerprint"],
        raw["blocker_classification"],
        raw["resume_condition"],
        raw["valid_until"]
      })

    valid =
      Enum.all?([
        raw["id"] == "act_" <> String.slice(expected_idempotency_key, 0, 32),
        Enum.all?(required_hashes, &hex_hash?(raw[&1])),
        raw["lineage_key"] == expected_lineage_key,
        raw["idempotency_key"] == expected_idempotency_key,
        hex_hash?(raw["policy_fingerprint"]),
        is_binary(raw["checkpoint"]),
        is_binary(raw["expected_postcondition"]),
        is_nil(raw["supersedes"]) or is_binary(raw["supersedes"])
      ])

    if valid, do: :ok, else: {:error, :identity_invalid}
  end

  defp hex_hash?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value)

  defp validate_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      _ -> {:error, :timestamp_invalid}
    end
  end

  defp validate_timestamp(_value), do: {:error, :timestamp_invalid}

  defp recover_dispatched(path, actions, order) do
    Enum.reduce_while(order, {:ok, actions, order}, fn id, {:ok, acc, retained_order} ->
      recover_dispatched_action(path, Map.fetch!(acc, id), acc, retained_order)
    end)
  end

  defp recover_dispatched_action(path, %Action{state: :dispatched} = action, actions, order) do
    recovered =
      update_action(action, :uncertain, %{"disposition" => "restart_reconciliation_required"})

    case persist(path, recovered) do
      :ok ->
        emit_transition(recovered, :dispatched)
        {:cont, {:ok, Map.put(actions, action.id, recovered), order}}

      {:error, reason} ->
        {:halt, {:error, {:ledger_recovery_write_failed, reason}}}
    end
  end

  defp recover_dispatched_action(_path, _action, actions, order),
    do: {:cont, {:ok, actions, order}}

  defp emit_transition(action, previous_state) do
    metadata = %{
      action_id: action.id,
      idempotency_key: action.idempotency_key,
      kind: action.kind,
      state: action.state,
      previous_state: previous_state,
      issue_id: action.source["issue_id"],
      task_id: action.source["task_id"],
      session_id: action.source["session_id"],
      checkpoint_hash: hash(action.checkpoint),
      policy_fingerprint: action.policy_fingerprint,
      blocker_classification: action.blocker_classification,
      resume_condition: action.resume_condition
    }

    :telemetry.execute([:symphony, :action_ledger, :transition], %{count: 1}, metadata)

    Logger.info("Action ledger transition action_id=#{action.id} kind=#{action.kind} previous_state=#{previous_state || "none"} state=#{action.state}")
  end
end
