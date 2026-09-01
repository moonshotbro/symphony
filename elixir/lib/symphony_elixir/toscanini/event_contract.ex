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

    fields =
      Enum.into([:specversion, :id, :source, :type, :subject, :time, :datacontenttype, :dataschema, :correlation_id, :causation_id], %{}, fn key ->
        {key, fetch_alias(attrs, key, Map.get(aliases, key, []))}
      end)

    {:ok, fields |> Map.put(:data, normalize_map(data)) |> then(&struct(__MODULE__, &1))}
  rescue
    ArgumentError -> {:error, :malformed_envelope}
  end

  defp normalize_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
  end

  defp normalize_map(_), do: %{}
  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)

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
    if e.specversion == "1.0" and Enum.all?(required, &present?/1), do: :ok, else: {:error, :malformed_envelope}
  end

  defp validate_data(data) when is_map(data) do
    required = [:envelope_version, :kind, :message_id, :correlation_id, :causation_id, :sender, :recipient, :authority_ref, :identity, :lifecycle, :evidence, :delivery, :privacy]

    identity_required = [:programme, :repo, :issue, :pr, :role, :task, :attempt, :fence, :idempotency, :exact_revision]
    delivery_required = [:idempotency_key, :sequence]

    if Enum.all?(required, &Map.has_key?(data, &1)) and
         present?(data.message_id) and present?(data.correlation_id) and
         is_map(data.identity) and Enum.all?(identity_required, &Map.has_key?(data.identity, &1)) and
         is_map(data.delivery) and Enum.all?(delivery_required, &Map.has_key?(data.delivery, &1)) and
         is_map(data.lifecycle) and
         is_map(data.privacy), do: :ok, else: {:error, :malformed_data}
  end

  defp validate_data(_), do: {:error, :malformed_data}

  defp validate_kind_and_type(%{data: %{kind: kind}, type: type}) do
    cond do
      not is_binary(type) -> {:error, :unsupported_message_type}
      kind == "command" and String.starts_with?(type, "sysmiq.command.") and command_name(type) in @commands -> :ok
      kind == "event" and String.starts_with?(type, "sysmiq.work.") and event_name(type) in @events -> :ok
      true -> {:error, :unsupported_message_type}
    end
  end

  defp validate_privacy(%{privacy: privacy} = data) do
    prohibited = [:body, :prompt, :message_body, :tool_arguments, :tool_results, :reasoning, :secret, :token]
    if privacy[:classification] == "restricted" or contains_prohibited?(data, prohibited), do: {:error, :privacy_prohibited}, else: :ok
  end

  defp contains_prohibited?(map, prohibited) when is_map(map) do
    Enum.any?(map, fn {key, value} -> key in prohibited or contains_prohibited?(value, prohibited) end)
  end

  defp contains_prohibited?(list, prohibited) when is_list(list), do: Enum.any?(list, &contains_prohibited?(&1, prohibited))
  defp contains_prohibited?(_, _), do: false

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
  defp command_name(type), do: type |> String.trim_leading("sysmiq.command.") |> String.split(".") |> hd()
  defp event_name(type), do: type |> String.trim_leading("sysmiq.work.") |> String.split(".") |> hd()
  defp present?(value), do: value not in [nil, "", %{}]
end
