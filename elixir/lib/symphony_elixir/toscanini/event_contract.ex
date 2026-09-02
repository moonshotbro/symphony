# credo:disable-for-this-file
defmodule SymphonyElixir.Toscanini.EventContract do
  @moduledoc "Privacy-safe, deterministic Toscanini command and event contract."
  @version "1.0.0"
  @states ~w(discovered assessed ready claimed dispatched running checkpointed review_requested reconciled needs_input blocked context_exhausted usage_limited failed recovery_pending rejected cancelled archived dead_letter)
  @events ~w(accepted started checkpointed review_requested completed failed blocked needs_input cancelled context_exhausted usage_limited)
  @commands ~w(dispatch_requested review_requested integration_requested reconcile_requested needs_input_acknowledged archive_requested)
  @top ~w(specversion id source type subject time datacontenttype dataschema correlation_id causation_id data)
  @data ~w(envelope_version kind message_id correlation_id causation_id sender recipient authority_ref identity lifecycle evidence delivery privacy)
  @schemas %{
    sender: ~w(kind id role),
    recipient: ~w(kind id role),
    authority: ~w(repository issue pr url expected_revision),
    identity: ~w(programme repo issue pr role task attempt fence idempotency exact_revision),
    lifecycle: ~w(state terminal_reason blocking_reason requested_action),
    evidence: ~w(refs),
    ref: ~w(url digest kind),
    delivery: ~w(idempotency_key sequence),
    privacy: ~w(classification retention redacted)
  }
  @keys (@top ++ @data ++ Enum.flat_map(@schemas, fn {_, v} -> v end)) |> Enum.uniq() |> Enum.map(&String.to_atom/1)
  @limits %{depth: 6, entries: 64, string: 512, list: 32}
  defstruct [:specversion, :id, :source, :type, :subject, :time, :datacontenttype, :dataschema, :correlation_id, :causation_id, :data]

  defmodule State do
    @moduledoc false
    defstruct current: "discovered", revision: 0, seen_ids: MapSet.new(), last_sequence: 0, identity: nil
  end

  @type t :: %__MODULE__{}
  @type state :: %State{}
  @type result(a) :: {:ok, a} | {:error, atom() | {atom(), term()}}
  @spec envelope_version() :: String.t()
  def envelope_version, do: @version
  @spec states() :: [String.t()]
  def states, do: @states
  @spec new(term()) :: result(t())
  def new(value), do: safe(fn -> new_value(value) end)
  @spec validate(term()) :: :ok | {:error, atom() | {atom(), term()}}
  def validate(value), do: safe(fn -> validate_value(value) end)
  @spec command?(term()) :: boolean()
  def command?(%__MODULE__{data: %{kind: "command"}}), do: true
  def command?(_), do: false
  @spec event?(term()) :: boolean()
  def event?(%__MODULE__{data: %{kind: "event"}}), do: true
  def event?(_), do: false
  @spec initial_state() :: state()
  def initial_state, do: %State{}

  @spec initial_state(term()) :: state()
  def initial_state(identity) when is_map(identity) or is_nil(identity), do: %State{identity: identity}
  def initial_state(_), do: %State{}
  @spec transition(term(), term()) :: result(state())
  def transition(state, envelope), do: safe(fn -> transition_value(state, envelope) end)
  @spec replay(term()) :: result(state())
  def replay(values), do: safe(fn -> replay_value(values, initial_state()) end)

  @spec replay(term(), term()) :: result(state())
  def replay(values, state), do: safe(fn -> replay_value(values, state) end)

  defp new_value(value) when is_map(value) do
    with {:ok, envelope} <- normalize(value), :ok <- validate_value(envelope), do: {:ok, envelope}
  end

  defp new_value(_), do: {:error, :malformed_envelope}

  defp validate_value(%__MODULE__{} = e) do
    with :ok <- version(e.data), :ok <- cloud(e), :ok <- data(e.data), :ok <- correlations(e), :ok <- kind_type(e), :ok <- privacy(e.data), :ok <- bounds(e), do: :ok
  end

  defp validate_value(_), do: {:error, :malformed_envelope}

  defp transition_value(%State{} = state, envelope) do
    with :ok <- state_valid(state),
         {:ok, e} <- ensure(envelope),
         :ok <- validate_value(e),
         :ok <- factual(e),
         :ok <- same_identity(state, e),
         :ok <- unique(state, e),
         :ok <- sequential(state, e),
         {:ok, next} <- next(state.current, lifecycle(e)) do
      {:ok, %{state | current: next, revision: state.revision + 1, seen_ids: MapSet.put(state.seen_ids, e.id), last_sequence: sequence(e), identity: state.identity || identity(e)}}
    end
  end

  defp transition_value(_, _), do: {:error, :malformed_state}

  defp replay_value(values, %State{} = state) when is_list(values), do: replay_events(values, state, @limits.list)

  defp replay_value(_, _), do: {:error, :malformed_replay}

  defp replay_events([], state, _remaining), do: {:ok, state}

  defp replay_events([value | tail], state, remaining) when remaining > 0 do
    case transition_value(state, value) do
      {:ok, next} -> replay_events(tail, next, remaining - 1)
      error -> error
    end
  end

  defp replay_events([_ | _], _state, 0), do: {:error, :malformed_replay}
  defp replay_events(_, _, _), do: {:error, :malformed_replay}

  defp normalize(attrs) do
    with :ok <- keys(attrs, @top), {:ok, data} <- map(attrs[:data] || attrs["data"] || %{}, 1) do
      aliases = %{correlation_id: ["sysmiqcorrelationid"], causation_id: ["sysmiqcausationid"]}

      fields =
        Enum.into([:specversion, :id, :source, :type, :subject, :time, :datacontenttype, :dataschema, :correlation_id, :causation_id], %{}, fn key ->
          {key, fetch(attrs, key, Map.get(aliases, key, []))}
        end)

      {:ok, struct(__MODULE__, Map.put(fields, :data, data))}
    end
  end

  defp map(value, depth) when depth <= @limits.depth and is_map(value) and map_size(value) <= @limits.entries do
    Enum.reduce_while(value, {:ok, %{}, MapSet.new()}, fn {key, child}, {:ok, acc, seen} ->
      with {:ok, atom} <- key(key),
           false <- MapSet.member?(seen, atom),
           {:ok, normalized} <- value(child, depth + 1),
           do: {:cont, {:ok, Map.put(acc, atom, normalized), MapSet.put(seen, atom)}},
           else: (
             :error -> {:halt, {:error, :unknown_field}}
             true -> {:halt, {:error, :conflicting_field_alias}}
             error -> {:halt, error}
           )
    end)
    |> case do
      {:ok, normalized, _seen} -> {:ok, normalized}
      error -> error
    end
  end

  defp map(_, _), do: {:error, :malformed_data}
  defp value(_, depth) when depth > @limits.depth, do: {:error, :malformed_data}
  defp value(value, depth) when is_map(value), do: map(value, depth)

  defp value(value, depth) when is_list(value), do: normalize_list(value, [], @limits.list, depth)

  defp value(value, _depth) when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value), do: {:ok, value}

  defp value(_, _), do: {:error, :malformed_data}

  defp normalize_list([], acc, _remaining, _depth), do: {:ok, Enum.reverse(acc)}

  defp normalize_list([item | tail], acc, remaining, depth) when remaining > 0 do
    case value(item, depth + 1) do
      {:ok, normalized} -> normalize_list(tail, [normalized | acc], remaining - 1, depth)
      error -> error
    end
  end

  defp normalize_list([_ | _], _acc, 0, _depth), do: {:error, :malformed_data}
  defp normalize_list(_, _, _, _), do: {:error, :malformed_data}
  defp key(value) when is_atom(value), do: if(value in @keys, do: {:ok, value}, else: :error)
  defp key(value) when is_binary(value), do: Enum.find_value(@keys, :error, fn atom -> if value == Atom.to_string(atom), do: {:ok, atom} end)
  defp key(_), do: :error

  defp keys(map, allowed) when is_map(map) and map_size(map) <= @limits.entries do
    Enum.reduce_while(map, MapSet.new(), fn {key, _value}, seen ->
      case key(key) do
        {:ok, atom} ->
          if Atom.to_string(atom) in allowed do
            if MapSet.member?(seen, atom), do: {:halt, {:error, :conflicting_field_alias}}, else: {:cont, MapSet.put(seen, atom)}
          else
            {:halt, {:error, :unknown_field}}
          end

        _ ->
          {:halt, {:error, :unknown_field}}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp keys(_, _), do: {:error, :unknown_field}

  defp fetch(map, key, aliases) do
    Enum.reduce_while([key, Atom.to_string(key) | aliases], nil, fn candidate, _acc ->
      case Map.fetch(map, candidate) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp ensure(%__MODULE__{} = e), do: {:ok, e}
  defp ensure(map) when is_map(map), do: new_value(map)
  defp ensure(_), do: {:error, :malformed_envelope}

  defp version(%{envelope_version: @version}), do: :ok
  defp version(_), do: {:error, :unsupported_version}

  defp cloud(%__MODULE__{} = e) do
    required = [e.specversion, e.id, e.source, e.type, e.subject, e.dataschema, e.correlation_id]

    if e.specversion == "1.0" and Enum.all?(required, &binary?/1) and nullable_binary?(e.time) and nullable_binary?(e.datacontenttype) and nullable_binary?(e.causation_id),
      do: :ok,
      else: {:error, :malformed_envelope}
  end

  defp data(d) when is_map(d) do
    if schema?(d, @data) and schema?(d.sender, @schemas.sender) and schema?(d.recipient, @schemas.recipient) and schema?(d.authority_ref, @schemas.authority) and schema?(d.identity, @schemas.identity) and
         schema?(d.lifecycle, @schemas.lifecycle) and schema?(d.evidence, @schemas.evidence) and schema?(d.delivery, @schemas.delivery) and schema?(d.privacy, @schemas.privacy) and
         binary?(d.message_id) and binary?(d.correlation_id) and nullable_binary?(d.causation_id) and identity?(d.identity) and principal?(d.sender) and principal?(d.recipient) and
         authority?(d.authority_ref, d.identity) and lifecycle?(d.lifecycle) and delivery?(d.delivery) and privacy?(d.privacy) and evidence?(d.evidence, d.identity),
       do: :ok,
       else: {:error, :malformed_data}
  end

  defp data(_), do: {:error, :malformed_data}
  defp kind_type(%{data: %{kind: "event", lifecycle: %{state: state}}, type: "sysmiq.work." <> rest}) when state in @events and rest == state <> ".v1", do: :ok
  defp kind_type(%{data: %{kind: "command", lifecycle: %{requested_action: action}}, type: "sysmiq.command." <> rest}) when action in @commands and rest == action <> ".v1", do: :ok
  defp kind_type(_), do: {:error, :unsupported_message_type}

  defp correlations(%__MODULE__{} = e) do
    d = e.data

    if e.id == d.message_id and e.correlation_id == d.correlation_id and e.causation_id == d.causation_id and e.subject == subject(d.authority_ref) and source?(e.source, d.sender),
      do: :ok,
      else: {:error, :identity_mismatch}
  end

  defp subject(%{repository: repo, issue: issue}), do: "github:#{repo}##{issue}"
  defp source?(source, %{kind: kind, id: id}) when is_binary(source) and is_binary(kind) and is_binary(id), do: source == "urn:sysmiq:#{kind}:#{id}"
  defp source?(_, _), do: false

  # This is the single canonical parser for authority and evidence URLs.
  defp github(url) when is_binary(url) and byte_size(url) <= @limits.string do
    uri = URI.parse(url)

    if uri.scheme == "https" and uri.host == "github.com" and is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      case String.split(uri.path || "", "/", trim: true) do
        [owner, repo, resource, target] ->
          repository = owner <> "/" <> repo

          if repo?(repository) do
            case ref_kind(resource, target) do
              {:ok, kind} -> {:ok, %{repo: repository, kind: kind, target: target}}
              :error -> :error
            end
          else
            :error
          end

        _ ->
          :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp github(_), do: :error
  defp ref_kind("issues", x) when is_binary(x), do: if(x =~ ~r/^\d+$/, do: {:ok, :issue}, else: :error)
  defp ref_kind("pull", x) when is_binary(x), do: if(x =~ ~r/^\d+$/, do: {:ok, :pull_request}, else: :error)
  defp ref_kind("commit", x) when is_binary(x), do: if(x =~ ~r/^[0-9a-fA-F]{7,128}$/, do: {:ok, :commit}, else: :error)
  defp ref_kind(_, _), do: :error

  defp authority?(a, i) do
    schema?(a, @schemas.authority) and is_binary(a.repository) and repo?(a.repository) and positive?(a.issue) and nullable_positive?(a.pr) and binary?(a.url) and digest?(a.expected_revision) and
      a.repository == i.repo and a.issue == i.issue and a.pr == i.pr and a.expected_revision == i.exact_revision and authority_url?(a.url, i)
  end

  defp authority_url?(url, i) do
    case github(url) do
      {:ok, %{repo: repo, kind: :issue, target: target}} -> repo == i.repo and target == Integer.to_string(i.issue)
      {:ok, %{repo: repo, kind: :pull_request, target: target}} -> repo == i.repo and positive?(i.pr) and target == Integer.to_string(i.pr)
      {:ok, %{repo: repo, kind: :commit, target: target}} -> repo == i.repo and target == i.exact_revision
      _ -> false
    end
  end

  defp evidence?(%{refs: refs}, i) when is_list(refs), do: proper?(refs) and length(refs) <= @limits.list and Enum.all?(refs, &evidence_ref?(&1, i))
  defp evidence?(_, _), do: false

  defp evidence_ref?(ref, i) when is_map(ref) do
    if schema?(ref, @schemas.ref) do
      case github(ref.url) do
        {:ok, parsed} ->
          ref.kind in ["issue", "pull_request", "commit", "check", "review"] and
            (is_nil(ref.digest) or digest?(ref.digest)) and evidence_target?(parsed, ref.kind, i)

        :error ->
          false
      end
    else
      false
    end
  end

  defp evidence_ref?(_, _), do: false
  defp evidence_target?(%{repo: repo, kind: :issue, target: x}, "issue", i), do: repo == i.repo and x == Integer.to_string(i.issue)

  defp evidence_target?(%{repo: repo, kind: :pull_request, target: x}, kind, i) when kind in ["pull_request", "check", "review"],
    do: repo == i.repo and positive?(i.pr) and x == Integer.to_string(i.pr)

  defp evidence_target?(%{repo: repo, kind: :commit, target: x}, "commit", i), do: repo == i.repo and x == i.exact_revision
  defp evidence_target?(_, _, _), do: false

  defp identity?(i) when is_map(i),
    do:
      schema?(i, @schemas.identity) and binary?(i.programme) and repo?(i.repo) and positive?(i.issue) and nullable_positive?(i.pr) and
        i.role in ["programme", "implementation", "independent_review", "landing", "recovery", "research", "monitor", "telemetry", "acceptance"] and binary?(i.task) and is_integer(i.attempt) and
        i.attempt >= 0 and is_integer(i.fence) and i.fence >= 0 and binary?(i.idempotency) and digest?(i.exact_revision)

  defp identity?(_), do: false
  defp principal?(p) when is_map(p), do: schema?(p, @schemas.sender) and p.kind in ["worker", "role", "adapter"] and binary?(p.id) and binary?(p.role)
  defp principal?(_), do: false
  defp lifecycle?(l), do: binary?(l.state) and nullable_binary?(l.terminal_reason) and nullable_binary?(l.blocking_reason) and nullable_binary?(l.requested_action)
  defp delivery?(d), do: binary?(d.idempotency_key) and positive?(d.sequence)
  defp privacy?(p), do: p.classification in ["metadata", "confidential"] and p.retention in ["audit", "operational"] and is_boolean(p.redacted)
  defp binary?(x), do: is_binary(x) and byte_size(x) in 1..@limits.string
  defp nullable_binary?(nil), do: true
  defp nullable_binary?(x), do: binary?(x)
  defp positive?(x), do: is_integer(x) and x > 0
  defp nullable_positive?(nil), do: true
  defp nullable_positive?(x), do: positive?(x)
  defp digest?(x), do: is_binary(x) and x =~ ~r/^[0-9a-fA-F]{7,128}$/
  defp repo?(x), do: is_binary(x) and x =~ ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/

  defp privacy(d) do
    bad = [:body, :prompt, :message_body, :tool_arguments, :tool_results, :reasoning, :secret, :token]
    if prohibited?(d, bad) or unsafe?(d), do: {:error, :privacy_prohibited}, else: :ok
  end

  defp prohibited?(m, keys) when is_map(m), do: Enum.any?(m, fn {k, v} -> k in keys or prohibited?(v, keys) end)
  defp prohibited?(xs, keys) when is_list(xs), do: proper?(xs) and Enum.any?(xs, &prohibited?(&1, keys))
  defp prohibited?(_, _), do: false
  defp unsafe?(m) when is_map(m), do: Enum.any?(m, fn {_, v} -> unsafe?(v) end)
  defp unsafe?(xs) when is_list(xs), do: proper?(xs) and Enum.any?(xs, &unsafe?/1)

  defp unsafe?(x) when is_binary(x) do
    down = String.downcase(x)

    String.contains?(x, ["/Users/", "/home/", "/tmp/", "~/", "BEGIN ", "file://", "\\\\"]) or String.match?(x, ~r{(?i)^[A-Z]:[\\/]}) or String.match?(x, ~r{(?i)^[^/\s:]+@[^:]+:.+}) or
      String.contains?(down, ["bearer ", "authorization:", "token=", "password=", "secret=", "api_key=", "private_key"])
  end

  defp unsafe?(_), do: false
  defp bounds(e), do: if(bounded?(e), do: :ok, else: {:error, :malformed_envelope})
  defp bounded?(%__MODULE__{} = e), do: bounded?(Map.from_struct(e), 0)
  defp bounded?(_, d) when d > @limits.depth, do: false
  defp bounded?(x, _) when is_nil(x) or is_boolean(x) or is_integer(x) or is_float(x), do: true
  defp bounded?(x, _) when is_binary(x), do: byte_size(x) <= @limits.string
  defp bounded?(x, d) when is_map(x), do: map_size(x) <= @limits.entries and Enum.all?(x, fn {k, v} -> (is_atom(k) or is_binary(k)) and bounded?(v, d + 1) end)
  defp bounded?(x, d) when is_list(x), do: proper?(x) and length(x) <= @limits.list and Enum.all?(x, &bounded?(&1, d + 1))
  defp bounded?(_, _), do: false

  defp proper?(value), do: proper?(value, 0)
  defp proper?([], _), do: true
  defp proper?([_ | tail], count) when count < @limits.list, do: proper?(tail, count + 1)
  defp proper?(_, _), do: false

  defp schema?(map, keys) when is_map(map),
    do: map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, String.to_atom(&1))) and Enum.all?(Map.keys(map), &(is_atom(&1) and Atom.to_string(&1) in keys))

  defp schema?(_, _), do: false
  defp factual(%{data: %{kind: "command"}}), do: {:error, :commands_are_not_factual_events}
  defp factual(_), do: :ok

  defp state_valid(%State{current: c, revision: r, seen_ids: ids, last_sequence: last, identity: identity}) do
    if (c in @states or c in @events) and is_integer(r) and r >= 0 and is_struct(ids, MapSet) and is_integer(last) and last >= 0 and (is_nil(identity) or identity?(identity)),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp same_identity(%State{identity: nil}, _), do: :ok
  defp same_identity(%State{identity: expected}, e), do: if(Map.delete(identity(e), :idempotency) == Map.delete(expected, :idempotency), do: :ok, else: {:error, :identity_mismatch})
  defp unique(%State{seen_ids: ids}, %{id: id}), do: if(MapSet.member?(ids, id), do: {:error, :duplicate_transition}, else: :ok)

  defp sequential(%State{last_sequence: last}, e) do
    case sequence(e) do
      x when x == last + 1 -> :ok
      x when is_integer(x) and x <= last -> {:error, :stale_transition}
      x when is_integer(x) -> {:error, :out_of_order_transition}
      _ -> {:error, :malformed_sequence}
    end
  end

  defp next(current, event) do
    paths = %{
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

    if current in Map.get(paths, event, []), do: {:ok, event}, else: {:error, {:illegal_transition, current, event}}
  end

  defp lifecycle(%{data: %{lifecycle: %{state: x}}}), do: x
  defp identity(%{data: %{identity: x}}), do: x
  defp sequence(%{data: %{delivery: %{sequence: x}}}), do: x

  defp safe(fun) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      _ -> {:error, :malformed_envelope}
    catch
      _, _ -> {:error, :malformed_envelope}
    end
  end
end
