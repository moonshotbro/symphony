# credo:disable-for-this-file
defmodule SymphonyElixir.Toscanini.EventContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Toscanini.EventContract

  defp event(id, seq, name, from \\ nil) do
    causation_id = from || if(seq == 1, do: nil, else: "e#{seq - 1}")
    refs = if(name == "cleanup_complete", do: [%{url: "https://github.com/moonshotbro/symphony/issues/51", digest: nil, kind: "issue"}], else: [])

    %{
      specversion: "1.0",
      id: id,
      source: "urn:sysmiq:worker:w1",
      type: "sysmiq.work.#{name}.v1",
      subject: "github:moonshotbro/symphony#51",
      dataschema: "urn:sysmiq:test:1",
      correlation_id: "run-1",
      causation_id: causation_id,
      data: %{
        envelope_version: "1.1.0",
        kind: "event",
        message_id: id,
        correlation_id: "run-1",
        causation_id: causation_id,
        sender: %{kind: "worker", id: "w1", role: "implementation"},
        recipient: %{kind: "role", id: "programme", role: "programme"},
        authority_ref: %{repository: "moonshotbro/symphony", issue: 51, pr: nil, url: "https://github.com/moonshotbro/symphony/issues/51", expected_revision: "abc1234"},
        identity: %{
          programme: "p1",
          repo: "moonshotbro/symphony",
          issue: 51,
          pr: nil,
          role: "execution_production",
          task: "t1",
          attempt: 0,
          fence: 1,
          idempotency: "i-#{id}",
          exact_revision: "abc1234",
          registry_id: "SYS-LIB-ROLE-REGISTRY-001",
          registry_version: "1.0",
          canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2",
          authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
          primary_role: "execution_production",
          domain_alias: "implementation worker",
          work_character: "bounded"
        },
        lifecycle: %{state: name, terminal_reason: nil, blocking_reason: nil, requested_action: nil},
        evidence: %{refs: refs},
        delivery: %{idempotency_key: "i-#{id}", sequence: seq},
        recovery: %{
          original_route: "sol",
          effective_route: "held",
          governed_effort: "medium",
          attempt: 1,
          budget: 32_000,
          resume_at: "2026-09-02T00:00:00Z",
          failure_class: "capacity",
          response_started: false,
          effect_uncertain: true,
          lifecycle: "held",
          outcome: "pending",
          circuit_state: "open"
        },
        privacy: %{classification: "metadata", retention: "audit", redacted: false}
      }
    }
  end

  defp nested_known_map(0, leaf), do: leaf
  defp nested_known_map(depth, leaf), do: %{kind: nested_known_map(depth - 1, leaf)}

  test "validates normalized event and keeps commands separate" do
    assert {:ok, envelope} = EventContract.new(event("e1", 1, "task_accepted"))
    assert EventContract.event?(envelope)
    assert :ok = EventContract.validate(envelope)

    command = %{
      event("c1", 1, "task_accepted")
      | type: "sysmiq.command.dispatch_requested.v1",
        data: envelope.data |> Map.put(:kind, "command") |> Map.put(:message_id, "c1") |> put_in([:lifecycle, :requested_action], "dispatch_requested")
    }

    assert {:ok, command} = EventContract.new(command)
    assert {:error, :commands_are_not_factual_events} = EventContract.transition(EventContract.initial_state(), command)
  end

  test "replays lifecycle deterministically and rejects duplicates and gaps" do
    events = [
      event("e1", 1, "task_accepted"),
      event("e2", 2, "durable_progress"),
      event("e3", 3, "candidate_ready"),
      event("e4", 4, "review_accepted"),
      event("e5", 5, "landed"),
      event("e6", 6, "cleanup_complete")
    ]

    assert {:ok, state} = EventContract.replay(events)
    assert state.current == "cleanup_complete"
    assert state.revision == 6
    assert {:error, :duplicate_operation} = EventContract.transition(state, hd(events))
    assert {:error, :out_of_order_transition} = EventContract.transition(EventContract.initial_state(), event("e2", 2, "durable_progress"))
  end

  test "rejects privacy-prohibited payloads and illegal state changes" do
    unsafe = put_in(event("e1", 1, "task_accepted").data[:body], "prompt")
    assert {:error, :unknown_field} = EventContract.new(unsafe)
    assert {:ok, state} = EventContract.transition(EventContract.initial_state(), event("e1", 1, "task_accepted"))
    assert {:error, {:illegal_transition, "task_accepted", "cleanup_complete"}} = EventContract.transition(state, event("e2", 2, "cleanup_complete"))
  end

  test "fails closed on unknown fields and contradictory outer identity" do
    unknown = put_in(event("e1", 1, "task_accepted").data[:unexpected], "x")
    assert {:error, :unknown_field} = EventContract.new(unknown)
    mismatch = %{event("e1", 1, "task_accepted") | id: "outer", correlation_id: "other"}
    assert {:error, :identity_mismatch} = EventContract.new(mismatch)
    suffix = %{event("e1", 1, "task_accepted") | type: "sysmiq.work.accepted.v1.injected"}
    assert {:error, :unsupported_message_type} = EventContract.new(suffix)
  end

  test "rejects conflicting atom and string field aliases at every contract boundary" do
    base = event("e1", 1, "task_accepted")

    assert {:error, :conflicting_field_alias} = EventContract.new(Map.put(base, "id", "other"))
    assert {:error, :conflicting_field_alias} = EventContract.new(put_in(base.data["kind"], "command"))

    assert {:error, :conflicting_field_alias} =
             EventContract.new(put_in(base.data[:authority_ref]["repository"], "other/repo"))

    assert {:error, :conflicting_field_alias} =
             EventContract.new(put_in(base.data[:evidence]["refs"], []))
  end

  test "does not create atoms for attacker-controlled keys" do
    key = "attacker_#{System.unique_integer([:positive])}"
    assert {:error, :unknown_field} = EventContract.new(put_in(event("e1", 1, "task_accepted").data[key], true))
    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(key, :utf8) end
  end

  test "rejects malformed nested objects, privacy values, and oversized content" do
    malformed = put_in(event("e1", 1, "task_accepted").data[:authority_ref], "not-an-object")
    assert {:error, :malformed_data} = EventContract.new(malformed)
    invalid_privacy = put_in(event("e1", 1, "task_accepted").data[:privacy][:classification], "public")
    assert {:error, :malformed_data} = EventContract.new(invalid_privacy)
    oversized = put_in(event("e1", 1, "task_accepted").data[:evidence][:refs], [String.duplicate("x", 513)])
    assert {:error, :malformed_data} = EventContract.new(oversized)
    deep = put_in(event("e1", 1, "task_accepted").data[:evidence][:refs], [%{url: "https://example.test", digest: "x", kind: %{nested: %{nested: %{nested: %{nested: %{nested: %{nested: true}}}}}}}])
    assert {:error, :unknown_field} = EventContract.new(deep)
    credential = put_in(event("e1", 1, "task_accepted").data[:identity][:task], "Bearer secret")
    assert {:error, :malformed_data} = EventContract.new(credential)
    bad_url = put_in(event("e1", 1, "task_accepted").data[:evidence][:refs], [%{url: "https://evil.test/x", kind: "commit"}])
    assert {:error, :malformed_data} = EventContract.new(bad_url)
    bad_pr = put_in(event("e1", 1, "task_accepted").data[:authority_ref][:pr], 4)
    assert {:error, :malformed_data} = EventContract.new(bad_pr)
  end

  test "authority is exact, complete, and bound to one canonical GitHub reference parser" do
    base = event("e1", 1, "task_accepted")

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
    assert {:ok, %EventContract{} = envelope} = EventContract.new(event("e1", 1, "task_accepted"))
    assert :ok = EventContract.validate(envelope)
    hostile_data = %{envelope.data | identity: %{envelope.data.identity | task: self()}}
    assert {:error, :malformed_data} = EventContract.validate(%EventContract{envelope | data: hostile_data})
    improper_evidence = %{envelope.data | evidence: %{envelope.data.evidence | refs: [1 | :tail]}}
    assert {:error, :malformed_data} = EventContract.validate(%EventContract{envelope | data: improper_evidence})
    assert {:error, :unknown_field} = EventContract.new(%{event("e1", 1, "task_accepted") | data: %{bad: fn -> :ok end}})
    assert {:error, :malformed_state} = EventContract.transition(%{}, envelope)
    assert {:error, :malformed_replay} = EventContract.replay([envelope | :tail])
  end

  test "rejects oversized input at the list limit before processing another element" do
    evidence_ref = %{url: "https://github.com/moonshotbro/symphony/issues/51", kind: "issue"}
    oversized_evidence = List.duplicate(evidence_ref, 33)

    assert {:error, :malformed_data} =
             EventContract.new(put_in(event("e1", 1, "task_accepted").data[:evidence][:refs], oversized_evidence))

    replay = Enum.map(1..32, &event("e#{&1}", &1, "cancelled")) ++ [self()]
    assert {:error, :malformed_replay} = EventContract.replay(replay, %EventContract.State{current: "running"})
  end

  test "rejects nested maps past the normalization depth budget before traversing the hostile leaf" do
    hostile_ref = nested_known_map(7, self())

    assert {:error, :malformed_data} =
             EventContract.new(put_in(event("e1", 1, "task_accepted").data[:evidence][:refs], [hostile_ref]))
  end

  test "requires a bounded typed provider-capacity recovery record" do
    base = event("e1", 1, "task_accepted")

    assert {:ok, envelope} = EventContract.new(base)
    assert envelope.data.recovery.effective_route == "held"
    assert envelope.data.recovery.effect_uncertain

    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:original_route], "https://provider.example"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:governed_effort], "unbounded"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:attempt], 33))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:budget], 1_000_001))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:resume_at], "customer data"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:response_started], "unknown"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:failure_class], "tool_payload"))
    assert {:error, :unknown_field} = EventContract.new(put_in(base.data[:recovery][:prompt], "customer data"))
    assert {:error, :unknown_field} = EventContract.new(put_in(base.data[:recovery][:arbitrary], %{nested: true}))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:identity][:task], "Customer Jane Doe medical diagnosis"))
  end
end
