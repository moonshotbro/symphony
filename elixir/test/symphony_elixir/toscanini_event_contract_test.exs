# credo:disable-for-this-file
defmodule SymphonyElixir.Toscanini.EventContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Toscanini.EventContract

  defp event(id, seq, name, from \\ nil) do
    %{
      specversion: "1.0",
      id: id,
      source: "urn:sysmiq:worker:w1",
      type: "sysmiq.work.#{name}.v1",
      subject: "github:moonshotbro/symphony#51",
      dataschema: "urn:sysmiq:test:1",
      correlation_id: "run-1",
      data: %{
        envelope_version: "1.0.0",
        kind: "event",
        message_id: id,
        correlation_id: "run-1",
        causation_id: from,
        sender: %{kind: "worker", id: "w1", role: "implementation"},
        recipient: %{kind: "role", id: "programme", role: "programme"},
        authority_ref: %{repository: "moonshotbro/symphony", issue: 51, pr: nil, url: "https://github.com/moonshotbro/symphony/issues/51", expected_revision: "abc1234"},
        identity: %{programme: "p1", repo: "moonshotbro/symphony", issue: 51, pr: nil, role: "implementation", task: "t1", attempt: 0, fence: 1, idempotency: "i-#{id}", exact_revision: "abc1234"},
        lifecycle: %{state: name, terminal_reason: nil, blocking_reason: nil, requested_action: nil},
        evidence: %{refs: []},
        delivery: %{idempotency_key: "i-#{id}", sequence: seq},
        privacy: %{classification: "metadata", retention: "audit", redacted: false}
      }
    }
  end

  test "validates normalized event and keeps commands separate" do
    assert {:ok, envelope} = EventContract.new(event("e1", 1, "accepted"))
    assert EventContract.event?(envelope)
    assert :ok = EventContract.validate(envelope)

    command = %{
      event("c1", 1, "accepted")
      | type: "sysmiq.command.dispatch_requested.v1",
        data: envelope.data |> Map.put(:kind, "command") |> Map.put(:message_id, "c1") |> put_in([:lifecycle, :requested_action], "dispatch_requested")
    }

    assert {:ok, command} = EventContract.new(command)
    assert {:error, :commands_are_not_factual_events} = EventContract.transition(EventContract.initial_state(), command)
  end

  test "replays lifecycle deterministically and rejects duplicates and gaps" do
    events = [event("e1", 1, "accepted"), event("e2", 2, "started"), event("e3", 3, "checkpointed"), event("e4", 4, "review_requested"), event("e5", 5, "completed")]
    assert {:ok, state} = EventContract.replay(events)
    assert state.current == "completed"
    assert state.revision == 5
    assert {:error, :duplicate_transition} = EventContract.transition(state, hd(events))
    assert {:error, :out_of_order_transition} = EventContract.transition(EventContract.initial_state(), event("e2", 2, "started"))
  end

  test "rejects privacy-prohibited payloads and illegal state changes" do
    unsafe = put_in(event("e1", 1, "accepted").data[:body], "prompt")
    assert {:error, :unknown_field} = EventContract.new(unsafe)
    assert {:ok, state} = EventContract.transition(EventContract.initial_state(), event("e1", 1, "accepted"))
    assert {:error, {:illegal_transition, "accepted", "completed"}} = EventContract.transition(state, event("e2", 2, "completed"))
  end

  test "fails closed on unknown fields and contradictory outer identity" do
    unknown = put_in(event("e1", 1, "accepted").data[:unexpected], "x")
    assert {:error, :unknown_field} = EventContract.new(unknown)
    mismatch = %{event("e1", 1, "accepted") | id: "outer", correlation_id: "other"}
    assert {:error, :identity_mismatch} = EventContract.new(mismatch)
    suffix = %{event("e1", 1, "accepted") | type: "sysmiq.work.accepted.v1.injected"}
    assert {:error, :unsupported_message_type} = EventContract.new(suffix)
  end

  test "rejects conflicting atom and string field aliases at every contract boundary" do
    base = event("e1", 1, "accepted")

    assert {:error, :conflicting_field_alias} = EventContract.new(Map.put(base, "id", "other"))
    assert {:error, :conflicting_field_alias} = EventContract.new(put_in(base.data["kind"], "command"))

    assert {:error, :conflicting_field_alias} =
             EventContract.new(put_in(base.data[:authority_ref]["repository"], "other/repo"))

    assert {:error, :conflicting_field_alias} =
             EventContract.new(put_in(base.data[:evidence]["refs"], []))
  end

  test "does not create atoms for attacker-controlled keys" do
    key = "attacker_#{System.unique_integer([:positive])}"
    assert {:error, :unknown_field} = EventContract.new(put_in(event("e1", 1, "accepted").data[key], true))
    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(key, :utf8) end
  end

  test "rejects malformed nested objects, privacy values, and oversized content" do
    malformed = put_in(event("e1", 1, "accepted").data[:authority_ref], "not-an-object")
    assert {:error, :malformed_data} = EventContract.new(malformed)
    invalid_privacy = put_in(event("e1", 1, "accepted").data[:privacy][:classification], "public")
    assert {:error, :malformed_data} = EventContract.new(invalid_privacy)
    oversized = put_in(event("e1", 1, "accepted").data[:evidence][:refs], [String.duplicate("x", 513)])
    assert {:error, :malformed_data} = EventContract.new(oversized)
    deep = put_in(event("e1", 1, "accepted").data[:evidence][:refs], [%{url: "https://example.test", digest: "x", kind: %{nested: %{nested: %{nested: %{nested: %{nested: %{nested: true}}}}}}}])
    assert {:error, :unknown_field} = EventContract.new(deep)
    credential = put_in(event("e1", 1, "accepted").data[:identity][:task], "Bearer secret")
    assert {:error, :privacy_prohibited} = EventContract.new(credential)
    bad_url = put_in(event("e1", 1, "accepted").data[:evidence][:refs], [%{url: "https://evil.test/x", kind: "commit"}])
    assert {:error, :malformed_data} = EventContract.new(bad_url)
    bad_pr = put_in(event("e1", 1, "accepted").data[:authority_ref][:pr], 4)
    assert {:error, :malformed_data} = EventContract.new(bad_pr)
  end

  test "authority is exact, complete, and bound to one canonical GitHub reference parser" do
    base = event("e1", 1, "accepted")

    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:authority_ref][:pr], 7))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:authority_ref][:expected_revision], nil))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:authority_ref][:url], "https://github.com/moonshotbro/symphony/issues/52"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:authority_ref][:url], "https://github.com/other/repo/issues/51"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:authority_ref][:url], "https://user:pass@github.com/moonshotbro/symphony/issues/51"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:authority_ref][:url], "https://github.com/moonshotbro/symphony/issues/51?token=x"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:authority_ref][:url], "git@github.com:moonshotbro/symphony.git"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:authority_ref][:url], "file:///tmp/issue"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:authority_ref], Map.delete(base.data.authority_ref, :url)))
  end

  test "direct struct validation and public helpers are total for hostile BEAM terms" do
    assert {:ok, %EventContract{} = envelope} = EventContract.new(event("e1", 1, "accepted"))
    assert :ok = EventContract.validate(envelope)
    hostile_data = %{envelope.data | identity: %{envelope.data.identity | task: self()}}
    assert {:error, :malformed_data} = EventContract.validate(%EventContract{envelope | data: hostile_data})
    improper_evidence = %{envelope.data | evidence: %{envelope.data.evidence | refs: [1 | :tail]}}
    assert {:error, :malformed_data} = EventContract.validate(%EventContract{envelope | data: improper_evidence})
    assert {:error, :unknown_field} = EventContract.new(%{event("e1", 1, "accepted") | data: %{bad: fn -> :ok end}})
    assert {:error, :malformed_state} = EventContract.transition(%{}, envelope)
    assert {:error, :malformed_replay} = EventContract.replay([envelope | :tail])
  end

  test "rejects oversized input at the list limit before processing another element" do
    evidence_ref = %{url: "https://github.com/moonshotbro/symphony/issues/51", kind: "issue"}
    oversized_evidence = List.duplicate(evidence_ref, 33)

    assert {:error, :malformed_data} =
             EventContract.new(put_in(event("e1", 1, "accepted").data[:evidence][:refs], oversized_evidence))

    replay = Enum.map(1..32, &event("e#{&1}", &1, "cancelled")) ++ [self()]
    assert {:error, :malformed_replay} = EventContract.replay(replay, %EventContract.State{current: "running"})
  end
end
