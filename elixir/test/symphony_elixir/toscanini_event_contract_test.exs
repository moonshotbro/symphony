# credo:disable-for-this-file
defmodule SymphonyElixir.Toscanini.EventContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Toscanini.EventContract

  defp event(id, seq, name, from \\ nil) do
    %{
      specversion: "1.0",
      id: id,
      source: "urn:test",
      type: "sysmiq.work.#{name}.v1",
      subject: "github:moonshotbro/symphony#51",
      dataschema: "urn:sysmiq:test:1",
      correlation_id: "run-1",
      data: %{
        envelope_version: "1.0",
        kind: "event",
        message_id: id,
        correlation_id: "run-1",
        causation_id: from,
        sender: %{kind: "worker", id: "w1", role: "implementation"},
        recipient: %{kind: "role", id: "programme", role: "programme"},
        authority_ref: %{repository: "moonshotbro/symphony", issue: 51},
        identity: %{programme: "p1", repo: "moonshotbro/symphony", issue: 51, pr: nil, role: "implementation", task: "t1", attempt: 0, fence: 1, idempotency: "i-#{id}", exact_revision: "abc1234"},
        lifecycle: %{state: name},
        evidence: %{refs: []},
        delivery: %{idempotency_key: "i-#{id}", sequence: seq},
        privacy: %{classification: "metadata", retention: "audit"}
      }
    }
  end

  test "validates normalized event and keeps commands separate" do
    assert {:ok, envelope} = EventContract.new(event("e1", 1, "accepted"))
    assert EventContract.event?(envelope)
    assert :ok = EventContract.validate(envelope)
    command = %{event("c1", 1, "accepted") | type: "sysmiq.command.dispatch_requested.v1", data: envelope.data |> Map.put(:kind, "command") |> Map.put(:message_id, "c1")}
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
end
