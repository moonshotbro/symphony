# credo:disable-for-this-file
defmodule SymphonyElixir.Toscanini.EventContract do
  @moduledoc """
  Privacy-safe, deterministic Toscanini command and event contract.

  This module is deliberately a pure value/transition boundary. It does not
  persist envelopes, deliver commands, or infer authority from an event.
  """

  @envelope_version "1.0.0"
  @states ~w(discovered assessed ready claimed dispatched running checkpointed review_requested reconciled needs_input blocked context_exhausted usage_limited failed recovery_pending rejected cancelled archived dead_letter)
  @events ~w(accepted started checkpointed review_requested completed failed blocked needs_input cancelled context_exhausted usage_limited)
  @commands ~w(dispatch_requested review_requested integration_requested reconcile_requested needs_input_acknowledged archive_requested)
  @top_keys ~w(specversion id source type subject time datacontenttype dataschema correlation_id causation_id data)
  @data_keys ~w(envelope_version kind message_id correlation_id causation_id sender recipient authority_ref identity lifecycle evidence delivery privacy)
  @delivery_keys [:idempotency_key, :sequence]
  @known_keys [
    :specversion,
    :id,
    :source,
    :type,
    :subject,
    :time,
    :datacontenttype,
    :dataschema,
    :correlation_id,
    :causation_id,
    :data,
    :envelope_version,
    :kind,
    :message_id,
    :sender,
    :recipient,
    :authority_ref,
    :identity,
    :lifecycle,
    :evidence,
    :delivery,
    :privacy,
    :programme,
    :repo,
    :issue,
    :pr,
    :role,
    :task,
    :attempt,
    :fence,
    :idempotency,
    :exact_revision,
    :idempotency_key,
    :sequence,
    :state,
    :terminal_reason,
    :blocking_reason,
    :requested_action,
    :classification,
    :retention,
    :redacted,
    :repository,
    :kind,
    :id,
    :url,
    :expected_revision,
    :refs,
    :digest
  ]
  @limits %{depth: 6, entries: 64, string: 512, list: 32}

  defstruct [:specversion, :id, :source, :type, :subject, :time, :datacontenttype, :dataschema, :correlation_id, :causation_id, :data]

  defmodule State do
    @moduledoc false
    defstruct current: "discovered", revision: 0, seen_ids: MapSet.new(), last_sequence: 0, identity: nil
  end

  @type t :: %__MODULE__{}
  @type state :: %State{}

  @spec envelope_version() :: String.t()
  def envelope_version, do: @envelope_version

  @spec states() :: [String.t()]
  def states, do: @states

  @spec new(map()) :: {:ok, t()} | {:error, atom() | {atom(), term()}}
  def new(attrs) when is_map(attrs) do
    with {:ok, envelope} <- normalize(attrs),
         :ok <- validate(envelope) do
      {:ok, envelope}
    end
  end

  def new(_), do: {:error, :malformed_envelope}

  @spec validate(t() | map()) :: :ok | {:error, atom() | {atom(), term()}}
  def validate(%__MODULE__{} = envelope) do
    with :ok <- validate_version(envelope.data),
         :ok <- validate_cloud_event(envelope),
         :ok <- validate_data(envelope.data),
         :ok <- validate_correlations(envelope),
         :ok <- validate_kind_and_type(envelope),
         :ok <- validate_privacy(envelope.data) do
      :ok
    end
  end

  def validate(_), do: {:error, :malformed_envelope}

  @spec command?(t()) :: boolean()
  def command?(%__MODULE__{data: %{kind: "command"}}), do: true
  def command?(_), do: false

  @spec event?(t()) :: boolean()
  def event?(%__MODULE__{data: %{kind: "event"}}), do: true
  def event?(_), do: false

  @spec initial_state(map() | nil) :: state()
  def initial_state(identity \\ nil), do: %State{identity: identity}

  @spec transition(state(), t() | map()) :: {:ok, state()} | {:error, atom() | {atom(), term()}}
  def transition(%State{} = state, envelope) do
    with {:ok, envelope} <- ensure_envelope(envelope),
         :ok <- validate(envelope),
         :ok <- reject_command_transition(envelope),
         :ok <- validate_identity(state, envelope),
         :ok <- reject_duplicate(state, envelope),
         :ok <- validate_sequence(state, envelope),
         {:ok, next} <- next_state(state.current, lifecycle(envelope)) do
      {:ok,
       %{state | current: next, revision: state.revision + 1, seen_ids: MapSet.put(state.seen_ids, envelope.id), last_sequence: sequence(envelope), identity: state.identity || identity(envelope)}}
    end
  end

  @spec replay([t() | map()], state()) :: {:ok, state()} | {:error, term()}
  def replay(envelopes, state \\ initial_state()) when is_list(envelopes) do
    Enum.reduce_while(envelopes, {:ok, state}, fn envelope, {:ok, current} ->
      case transition(current, envelope) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize(attrs) do
    data = fetch(attrs, :data, %{})

    aliases = %{correlation_id: ["sysmiqcorrelationid"], causation_id: ["sysmiqcausationid"]}

    with :ok <- validate_keys(attrs, @top_keys),
         {:ok, normalized_data} <- normalize_map(data) do
      fields =
        Enum.into([:specversion, :id, :source, :type, :subject, :time, :datacontenttype, :dataschema, :correlation_id, :causation_id], %{}, fn key ->
          {key, fetch_alias(attrs, key, Map.get(aliases, key, []))}
        end)

      {:ok, fields |> Map.put(:data, normalized_data) |> then(&struct(__MODULE__, &1))}
    end
  rescue
    ArgumentError -> {:error, :malformed_envelope}
  end

  defp normalize_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case safe_key(key) do
        {:ok, atom} ->
          case normalize_value(value) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, atom, normalized)}}
            error -> {:halt, error}
          end

        :error ->
          {:halt, {:error, :unknown_field}}
      end
    end)
  end

  defp normalize_map(_), do: {:error, :malformed_data}
  defp normalize_value(value) when is_map(value), do: normalize_map(value)

  defp normalize_value(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_value(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  defp normalize_value(value), do: {:ok, value}

  defp safe_key(key) when is_atom(key), do: if(key in @known_keys, do: {:ok, key}, else: :error)

  defp safe_key(key) when is_binary(key) do
    Enum.find_value(@known_keys, :error, fn known -> if key == Atom.to_string(known), do: {:ok, known} end)
  end

  defp safe_key(_), do: :error

  defp validate_keys(map, allowed) when is_map(map) do
    if Enum.all?(Map.keys(map), fn key -> (is_atom(key) and Atom.to_string(key) in allowed) or (is_binary(key) and key in allowed) end), do: :ok, else: {:error, :unknown_field}
  end

  defp fetch(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp fetch_alias(map, key, aliases) do
    Enum.find_value([key, Atom.to_string(key) | aliases], fn candidate -> Map.get(map, candidate) end)
  end

  defp ensure_envelope(%__MODULE__{} = envelope), do: {:ok, envelope}
  defp ensure_envelope(map) when is_map(map), do: new(map)
  defp ensure_envelope(_), do: {:error, :malformed_envelope}

  defp validate_version(%{envelope_version: version}) when version in [@envelope_version, "1.0"], do: :ok
  defp validate_version(_), do: {:error, :unsupported_version}

  defp validate_cloud_event(%__MODULE__{} = e) do
    required = [e.specversion, e.id, e.source, e.type, e.subject, e.dataschema, e.correlation_id]

    if e.specversion == "1.0" and Enum.all?(required, &present?/1) and
         Enum.all?(
           [e.id, e.source, e.type, e.subject, e.time, e.datacontenttype, e.dataschema, e.correlation_id, e.causation_id],
           &bounded?/1
         ), do: :ok, else: {:error, :malformed_envelope}
  end

  defp validate_data(data) when is_map(data) do
    required = [:envelope_version, :kind, :message_id, :correlation_id, :causation_id, :sender, :recipient, :authority_ref, :identity, :lifecycle, :evidence, :delivery, :privacy]

    identity_required = [:programme, :repo, :issue, :pr, :role, :task, :attempt, :fence, :idempotency, :exact_revision]
    delivery_required = @delivery_keys

    if bounded?(data) and object_keys?(data, @data_keys) and Enum.all?(required, &Map.has_key?(data, &1)) and
         present?(data.message_id) and present?(data.correlation_id) and
         is_map(data.identity) and Enum.all?(identity_required, &Map.has_key?(data.identity, &1)) and
         is_map(data.delivery) and Enum.all?(delivery_required, &Map.has_key?(data.delivery, &1)) and
         is_map(data.lifecycle) and
         is_map(data.privacy) and object_keys?(data.sender, ["kind", "id", "role"]) and
         object_keys?(data.recipient, ["kind", "id", "role"]) and
         object_keys?(data.authority_ref, ["repository", "issue", "pr", "url", "expected_revision"]) and
         object_keys?(data.identity, ["programme", "repo", "issue", "pr", "role", "task", "attempt", "fence", "idempotency", "exact_revision"]) and
         object_keys?(data.lifecycle, ["state", "terminal_reason", "blocking_reason", "requested_action"]) and
         object_keys?(data.delivery, ["idempotency_key", "sequence"]) and
         object_keys?(data.evidence, ["refs"]) and evidence_valid?(data.evidence) and
         object_keys?(data.privacy, ["classification", "retention", "redacted"]), do: validate_types(data), else: {:error, :malformed_data}
  end

  defp validate_data(_), do: {:error, :malformed_data}

  defp validate_kind_and_type(%{data: %{kind: kind}, type: type}) do
    cond do
      not is_binary(type) -> {:error, :unsupported_message_type}
      kind == "command" and type in Enum.map(@commands, &"sysmiq.command.#{&1}.v1") -> :ok
      kind == "event" and type in Enum.map(@events, &"sysmiq.work.#{&1}.v1") -> :ok
      true -> {:error, :unsupported_message_type}
    end
  end

  defp validate_correlations(%__MODULE__{} = e) do
    data = e.data

    if e.id == data.message_id and e.correlation_id == data.correlation_id and
         e.causation_id == data.causation_id and
         authority_matches?(e.subject, data.authority_ref) and
         identity_authority_matches?(data.identity, data.authority_ref), do: :ok, else: {:error, :identity_mismatch}
  end

  defp authority_subject(%{repository: repo, issue: issue}), do: "github:#{repo}##{issue}"
  defp authority_subject(_), do: nil
  defp authority_matches?(_subject, authority) when not is_map(authority), do: false
  defp authority_matches?(subject, authority), do: subject == authority_subject(authority) or subject == "github:" <> to_string(authority[:repository]) <> "#" <> to_string(authority[:issue])
  defp identity_authority_matches?(%{repo: repo, issue: issue}, %{repository: repo, issue: issue}), do: true
  defp identity_authority_matches?(_, _), do: false

  defp evidence_valid?(%{refs: refs}) when is_list(refs) and length(refs) <= 32 do
    Enum.all?(refs, fn ref ->
      is_map(ref) and object_keys?(ref, ["url", "digest", "kind"]) and
        is_binary(ref[:url]) and String.starts_with?(ref[:url], "https://") and bounded?(ref)
    end)
  end

  defp evidence_valid?(_), do: false
  defp object_keys?(map, allowed) when is_map(map), do: Enum.all?(Map.keys(map), &(is_atom(&1) and Atom.to_string(&1) in allowed))
  defp object_keys?(_, _), do: false
  defp bounded?(term), do: bounded?(term, 0)
  defp bounded?(_, depth) when depth > @limits.depth, do: false
  defp bounded?(value, _depth) when is_binary(value), do: byte_size(value) <= @limits.string
  defp bounded?(value, depth) when is_map(value), do: map_size(value) <= @limits.entries and Enum.all?(value, fn {k, v} -> bounded?(k, depth + 1) and bounded?(v, depth + 1) end)
  defp bounded?(value, depth) when is_list(value), do: length(value) <= @limits.list and Enum.all?(value, &bounded?(&1, depth + 1))
  defp bounded?(_, _), do: true

  defp validate_types(data) do
    privacy = data.privacy

    if is_binary(data.lifecycle.state) and is_binary(data.delivery.idempotency_key) and is_integer(data.delivery.sequence) and
         privacy.classification in ["metadata", "confidential"] and privacy.retention in ["audit", "operational"] and
         is_boolean(Map.get(privacy, :redacted, false)), do: :ok, else: {:error, :malformed_data}
  end

  defp validate_privacy(%{privacy: privacy} = data) do
    prohibited = [:body, :prompt, :message_body, :tool_arguments, :tool_results, :reasoning, :secret, :token]
    if privacy[:classification] == "restricted" or contains_prohibited?(data, prohibited) or unsafe_value?(data), do: {:error, :privacy_prohibited}, else: :ok
  end

  defp contains_prohibited?(map, prohibited) when is_map(map) do
    Enum.any?(map, fn {key, value} -> key in prohibited or contains_prohibited?(value, prohibited) end)
  end

  defp contains_prohibited?(list, prohibited) when is_list(list), do: Enum.any?(list, &contains_prohibited?(&1, prohibited))
  defp contains_prohibited?(_, _), do: false
  defp unsafe_value?(map) when is_map(map), do: Enum.any?(map, fn {_key, value} -> unsafe_value?(value) end)
  defp unsafe_value?(list) when is_list(list), do: Enum.any?(list, &unsafe_value?/1)

  defp unsafe_value?(value) when is_binary(value) do
    down = String.downcase(value)

    String.contains?(value, ["/Users/", "/home/", "BEGIN "]) or
      String.contains?(down, ["bearer ", "token=", "password=", "secret="])
  end

  defp unsafe_value?(_), do: false

  defp reject_command_transition(%{data: %{kind: "command"}}), do: {:error, :commands_are_not_factual_events}
  defp reject_command_transition(_), do: :ok

  defp validate_identity(%State{identity: nil}, _), do: :ok

  defp validate_identity(%State{identity: expected}, envelope) do
    if stable_identity(identity(envelope)) == stable_identity(expected), do: :ok, else: {:error, :identity_mismatch}
  end

  defp validate_sequence(%State{last_sequence: last}, envelope) do
    seq = sequence(envelope)

    cond do
      not is_integer(seq) -> {:error, :malformed_sequence}
      seq == last + 1 -> :ok
      seq <= last -> {:error, :stale_transition}
      true -> {:error, :out_of_order_transition}
    end
  end

  defp reject_duplicate(%State{seen_ids: seen}, %{id: id}) do
    if MapSet.member?(seen, id), do: {:error, :duplicate_transition}, else: :ok
  end

  defp next_state(current, event) do
    transitions = %{
      "accepted" => ["discovered", "assessed", "ready"],
      "started" => ["accepted", "claimed", "dispatched", "running"],
      "checkpointed" => ["started", "running"],
      "review_requested" => ["running", "checkpointed"],
      "completed" => ["review_requested", "reconciled"],
      "failed" => ["running", "checkpointed", "recovery_pending"],
      "blocked" => ["running", "ready", "claimed"],
      "needs_input" => ["running", "blocked"],
      "cancelled" => @states,
      "context_exhausted" => ["running", "checkpointed"],
      "usage_limited" => ["running", "checkpointed"]
    }

    if current in Map.get(transitions, event, []), do: {:ok, event}, else: {:error, {:illegal_transition, current, event}}
  end

  defp lifecycle(%{data: %{lifecycle: %{state: state}}}), do: state
  defp lifecycle(_), do: nil
  defp identity(%{data: %{identity: identity}}), do: identity
  defp stable_identity(identity), do: Map.delete(identity, :idempotency)
  defp sequence(%{data: %{delivery: %{sequence: sequence}}}) when is_integer(sequence), do: sequence
  defp sequence(_), do: nil
  defp present?(value), do: value not in [nil, "", %{}]
end
