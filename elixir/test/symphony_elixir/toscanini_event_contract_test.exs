# credo:disable-for-this-file
defmodule SymphonyElixir.Toscanini.EventContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Toscanini.EventContract

  defp event(id, seq, name, from \\ nil) do
    %{
      specversion: "1.0",
      id: id,
      source: "urn:test",
      type: "sysmiq.work.#{name}",
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
        identity: %{programme: "p1", repo: "moonshotbro/symphony", issue: 51, pr: nil, role: "implementation", task: "t1", attempt: 0, fence: 1, idempotency: "i-#{id}", exact_revision: "abc"},
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
    command = %{event("c1", 1, "accepted") | type: "sysmiq.command.dispatch_requested", data: Map.put(envelope.data, :kind, "command")}
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
    assert {:error, :privacy_prohibited} = EventContract.new(unsafe)
    assert {:ok, state} = EventContract.transition(EventContract.initial_state(), event("e1", 1, "accepted"))
    assert {:error, {:illegal_transition, "accepted", "completed"}} = EventContract.transition(state, event("e2", 2, "completed"))
  end
end
