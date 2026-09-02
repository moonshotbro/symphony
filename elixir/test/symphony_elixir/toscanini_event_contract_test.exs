# credo:disable-for-this-file
defmodule SymphonyElixir.Toscanini.EventContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Toscanini.EventContract
  alias SymphonyElixir.Codex.TaskAccountabilityRegistry

  @head String.duplicate("a", 40)

  defp risk_assurance(overrides \\ %{}) do
    Map.merge(
      %{
        schema: "sysmiq.symphony.risk-assurance.v1",
        repository: "moonshotbro/symphony",
        head_sha: @head,
        risk_receipt_digest: String.duplicate("b", 64),
        assurance_receipt_digest: String.duplicate("c", 64),
        evidence_manifest_digest: String.duplicate("d", 64),
        matrix_revision: "risk-matrix-v1",
        required_gate_ids: ["G-EXACT-HEAD-REVIEW"],
        artifact_url: "https://github.com/moonshotbro/symphony/actions/runs/51/artifacts",
        stage: "review",
        assurance_outcome: "unresolved"
      },
      overrides
    )
  end

  defp event(id, seq, name, from \\ nil) do
    causation_id = from || if(seq == 1, do: nil, else: "e#{seq - 1}")
    refs = if(name in ["cleanup_complete", "superseded", "failed", "cancelled"], do: [%{url: "https://github.com/moonshotbro/symphony/issues/51", digest: nil, kind: "issue"}], else: [])

    projection =
      case name do
        "candidate_ready" ->
          risk_assurance()

        "review_accepted" ->
          risk_assurance(%{
            stage: "landing",
            assurance_outcome: "pass",
            assurance_receipt_digest: String.duplicate("e", 64),
            evidence_manifest_digest: String.duplicate("f", 64),
            artifact_url: "https://github.com/moonshotbro/symphony/actions/runs/52/artifacts"
          })

        "landed" ->
          risk_assurance(%{
            stage: "landing",
            assurance_outcome: "pass",
            assurance_receipt_digest: String.duplicate("e", 64),
            evidence_manifest_digest: String.duplicate("f", 64),
            artifact_url: "https://github.com/moonshotbro/symphony/actions/runs/52/artifacts"
          })

        _ ->
          nil
      end

    %{
      specversion: "1.0",
      id: id,
      source: "urn:sysmiq:worker:worker-000000000000000000000000000000e1",
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
        sender: %{kind: "worker", id: "worker-000000000000000000000000000000e1", role: "implementation"},
        recipient: %{kind: "role", id: "programme", role: "programme"},
        authority_ref: %{repository: "moonshotbro/symphony", issue: 51, pr: nil, url: "https://github.com/moonshotbro/symphony/issues/51", expected_revision: @head},
        identity: %{
          programme: "programme-000000000000000000000000000000e1",
          repo: "moonshotbro/symphony",
          issue: 51,
          pr: nil,
          role: "execution_production",
          task: "task-00000000000000000000000000000001",
          attempt: 0,
          fence: 1,
          idempotency: "op-#{String.pad_leading(id, 32, "0")}",
          exact_revision: @head,
          registry_id: "SYS-LIB-ROLE-REGISTRY-001",
          registry_version: "1.0",
          canonical_digest: "a88eb4f4d35806679e7df9dde7885ae25a1b362306a08efd187b16717cf28fc2",
          authority_revision: "7cce0ffd5a7ebb6980b6754b996b81fed108023b",
          primary_role: "execution_production",
          domain_alias: "implementation worker",
          work_character: "bounded"
        },
        lifecycle: %{state: name, terminal_reason: nil, blocking_reason: nil, requested_action: nil},
        evidence: if(projection, do: %{refs: refs, risk_assurance: projection}, else: %{refs: refs}),
        delivery: %{idempotency_key: "op-#{String.pad_leading(id, 32, "0")}", sequence: seq},
        recovery: %{
          original_route: "sol",
          effective_route: "sol",
          attempted_routes: ["sol"],
          governed_effort: "medium",
          goal_id: "goal-00000000000000000000000000000051",
          operation_id: "op-#{String.pad_leading(id, 32, "0")}",
          attempt: 0,
          retry_after_ms: 0,
          retries_remaining: 0,
          failure_class: "none",
          response_started: false,
          effect_uncertain: false,
          lifecycle: "not_required",
          outcome: "not_started",
          circuit_state: "closed",
          next_safe_action: "none"
        },
        privacy: %{classification: "structural_metadata", retention: "audit", redacted: true}
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
      | type: "sysmiq.command.start.v1",
        data: envelope.data |> Map.put(:kind, "command") |> Map.put(:message_id, "c1") |> put_in([:lifecycle, :requested_action], "start")
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
    assert {:error, :terminal_state} = EventContract.transition(state, hd(events))
    assert {:error, :causation_mismatch} = EventContract.transition(EventContract.initial_state(), event("e2", 2, "durable_progress"))
  end

  test "binds staged risk assurance to the exact review and landing head" do
    candidate = event("e3", 3, "candidate_ready", "e2")
    accepted = event("e4", 4, "review_accepted", "e3")
    landed = event("e5", 5, "landed", "e4")
    previous = [event("e1", 1, "task_accepted"), event("e2", 2, "durable_progress")]

    assert {:error, :missing_risk_assurance} =
             EventContract.replay(previous ++ [put_in(candidate.data[:evidence], %{refs: []})])

    assert {:error, :malformed_data} =
             EventContract.new(put_in(candidate.data[:evidence][:risk_assurance][:repository], "other/repository"))

    assert {:error, :malformed_data} =
             EventContract.new(put_in(candidate.data[:evidence][:risk_assurance][:head_sha], String.duplicate("e", 40)))

    assert {:error, :risk_assurance_stage_invalid} =
             EventContract.replay(previous ++ [put_in(candidate.data[:evidence][:risk_assurance][:assurance_outcome], "pass")])

    assert {:ok, state} = EventContract.replay(previous ++ [candidate, accepted])

    assert {:error, :risk_assurance_mismatch} =
             EventContract.transition(state, put_in(landed.data[:evidence][:risk_assurance][:assurance_receipt_digest], String.duplicate("d", 64)))

    assert {:error, :risk_assurance_stage_invalid} =
             EventContract.transition(state, put_in(accepted.data[:evidence][:risk_assurance][:assurance_outcome], "unresolved"))
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
    assert {:error, :terminal_state} = EventContract.replay(replay, %EventContract.State{current: "running"})
  end

  test "rejects nested maps past the normalization depth budget before traversing the hostile leaf" do
    hostile_ref = nested_known_map(7, self())

    assert {:error, :malformed_data} =
             EventContract.new(put_in(event("e1", 1, "task_accepted").data[:evidence][:refs], [hostile_ref]))
  end

  test "requires a bounded typed provider-capacity recovery record" do
    base = event("e1", 1, "task_accepted")

    assert {:ok, envelope} = EventContract.new(base)
    assert envelope.data.recovery.effective_route == "sol"
    refute envelope.data.recovery.effect_uncertain

    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:original_route], "https://provider.example"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:governed_effort], "unbounded"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:attempt], 33))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:retry_after_ms], 1_000_001))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:attempted_routes], ["luna", "sol"]))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:response_started], "unknown"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:failure_class], "tool_payload"))
    assert {:error, :unknown_field} = EventContract.new(put_in(base.data[:recovery][:prompt], "customer data"))
    assert {:error, :unknown_field} = EventContract.new(put_in(base.data[:recovery][:arbitrary], %{nested: true}))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:identity][:task], "Customer Jane Doe medical diagnosis"))
  end

  test "accepts the factual attention and judgment lifecycle and rejects dead transitions" do
    events = [
      event("e1", 1, "task_accepted"),
      event("e2", 2, "durable_progress"),
      event("e3", 3, "attention"),
      event("e4", 4, "needs_judgment"),
      event("e5", 5, "resume"),
      event("e6", 6, "durable_progress")
    ]

    assert {:ok, %{current: "durable_progress"}} = EventContract.replay(events)
    assert {:ok, _} = EventContract.new(event("e7", 1, "blocked"))
    assert {:ok, _} = EventContract.new(event("e8", 1, "needs_judgment"))
    assert {:error, :malformed_data} = EventContract.new(event("old", 1, "needs_input"))
  end

  test "fails closed on root causation, terminal evidence, aliases, and free-text lifecycle metadata" do
    assert {:error, :causation_mismatch} = EventContract.transition(EventContract.initial_state(), event("e1", 1, "task_accepted", "ghost"))

    chain = [
      event("e1", 1, "task_accepted"),
      event("e2", 2, "durable_progress"),
      event("e3", 3, "candidate_ready"),
      event("e4", 4, "review_accepted"),
      event("e5", 5, "landed"),
      put_in(event("e6", 6, "cleanup_complete").data[:evidence][:refs], [])
    ]

    assert {:error, :missing_terminal_evidence} = EventContract.replay(chain)
    assert {:error, :malformed_data} = EventContract.new(put_in(event("e1", 1, "task_accepted").data[:identity][:domain_alias], "Customer Jane Doe medical diagnosis"))
    assert {:error, :malformed_data} = EventContract.new(put_in(event("e1", 1, "task_accepted").data[:identity][:domain_alias], "landing owner"))
    assert {:error, :malformed_data} = EventContract.new(put_in(event("e1", 1, "task_accepted").data[:lifecycle][:blocking_reason], "Customer Jane Doe medical diagnosis"))
  end

  test "requires ordered and semantically coherent Sol Terra Luna recovery" do
    base = event("e1", 1, "task_accepted")

    resumed = %{
      base.data.recovery
      | effective_route: "luna",
        attempted_routes: ["sol", "terra", "luna"],
        failure_class: "capacity",
        lifecycle: "resumed",
        outcome: "recovered",
        circuit_state: "closed"
    }

    assert {:ok, _} = EventContract.new(put_in(base.data[:recovery], resumed))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery][:attempted_routes], ["luna", "sol"]))

    held = %{
      base.data.recovery
      | effective_route: "held",
        attempted_routes: ["sol"],
        failure_class: "none",
        response_started: true,
        effect_uncertain: false,
        lifecycle: "held",
        outcome: "pending",
        circuit_state: "open",
        next_safe_action: "attention"
    }

    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery], held))
  end

  test "replays ordinary progress into every accepted terminal outcome and keeps dispatch command support" do
    for terminal <- ["failed", "cancelled", "superseded"] do
      assert {:ok, %{current: ^terminal}} = EventContract.replay([event("e1", 1, "task_accepted"), event("e2", 2, "durable_progress"), event("e3", 3, terminal)])
    end

    command = %{
      event("c1", 1, "task_accepted")
      | type: "sysmiq.command.dispatch_requested.v1",
        data: event("c1", 1, "task_accepted").data |> Map.put(:kind, "command") |> put_in([:lifecycle, :requested_action], "dispatch_requested")
    }

    assert {:ok, _} = EventContract.new(command)
  end

  test "uses every accepted registry alias and rejects cross-role aliases and customer structural fields" do
    for {role, alias_name} <- [
          {"execution_production", "implementation worker"},
          {"verification_assessment", "independent reviewer"},
          {"investigation_evidence", "evidence worker"},
          {"planning_coordination", "programme conductor"},
          {"engagement_service", "customer service"},
          {"response_recovery", "incident response"},
          {"integration_closeout", "landing owner"}
        ] do
      candidate = event("e1", 1, "task_accepted") |> put_in([:data, :identity, :role], role) |> put_in([:data, :identity, :primary_role], role) |> put_in([:data, :identity, :domain_alias], alias_name)
      assert {:ok, _} = EventContract.new(candidate)
    end

    assert {:error, :malformed_data} = EventContract.new(put_in(event("e1", 1, "task_accepted").data[:identity][:domain_alias], "landing owner"))
    assert {:error, :malformed_data} = EventContract.new(put_in(event("e1", 1, "task_accepted").data[:identity][:programme], "Customer Jane Doe medical diagnosis"))
    assert {:error, :malformed_data} = EventContract.new(put_in(event("e1", 1, "task_accepted").data[:sender][:role], "Customer Jane Doe medical diagnosis"))
  end

  test "binds effective recovery routes and contradictory abandoned states to the ordered attempt record" do
    base = event("e1", 1, "task_accepted")

    scheduled = %{
      base.data.recovery
      | effective_route: "luna",
        attempted_routes: ["sol"],
        failure_class: "capacity",
        response_started: true,
        effect_uncertain: false,
        lifecycle: "scheduled",
        outcome: "pending",
        circuit_state: "open",
        retry_after_ms: 1,
        retries_remaining: 1,
        next_safe_action: "retry"
    }

    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery], scheduled))

    resumed = %{
      scheduled
      | response_started: false,
        effect_uncertain: false,
        lifecycle: "resumed",
        outcome: "recovered",
        circuit_state: "closed",
        retry_after_ms: 0,
        retries_remaining: 0,
        next_safe_action: "none"
    }

    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery], resumed))

    abandoned = %{
      base.data.recovery
      | failure_class: "none",
        response_started: true,
        effect_uncertain: false,
        lifecycle: "abandoned",
        outcome: "failed",
        circuit_state: "closed",
        next_safe_action: "none"
    }

    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery], abandoned))
  end

  test "keeps terminal states absorbing" do
    completed = [
      event("e1", 1, "task_accepted"),
      event("e2", 2, "durable_progress"),
      event("e3", 3, "candidate_ready"),
      event("e4", 4, "review_accepted"),
      event("e5", 5, "landed"),
      event("e6", 6, "cleanup_complete")
    ]

    assert {:ok, state} = EventContract.replay(completed)
    assert {:error, :terminal_state} = EventContract.transition(state, event("e7", 7, "failed", "e6"))
  end

  test "accepts every registry default self alias and rejects cross-role aliases" do
    for role <- TaskAccountabilityRegistry.roles() do
      candidate = event("e1", 1, "task_accepted") |> put_in([:data, :identity, :role], role) |> put_in([:data, :identity, :primary_role], role) |> put_in([:data, :identity, :domain_alias], role)
      assert {:ok, _} = EventContract.new(candidate)
    end

    crossed =
      event("e1", 1, "task_accepted")
      |> put_in([:data, :identity, :role], "response_recovery")
      |> put_in([:data, :identity, :primary_role], "response_recovery")
      |> put_in([:data, :identity, :domain_alias], "implementation worker")

    assert {:error, :malformed_data} = EventContract.new(crossed)
  end

  test "rejects route-mismatched abandoned recovery and accepts coherent recovery attention" do
    base = event("e1", 1, "task_accepted")

    abandoned = %{
      base.data.recovery
      | effective_route: "luna",
        attempted_routes: ["sol"],
        failure_class: "capacity",
        response_started: true,
        effect_uncertain: true,
        lifecycle: "abandoned",
        outcome: "failed",
        circuit_state: "open",
        next_safe_action: "abandon"
    }

    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:recovery], abandoned))

    attention = %{
      base.data.recovery
      | effective_route: "held",
        failure_class: "capacity",
        response_started: true,
        effect_uncertain: true,
        lifecycle: "attention",
        outcome: "attention",
        circuit_state: "open",
        next_safe_action: "attention"
    }

    assert {:ok, _} = EventContract.new(put_in(base.data[:recovery], attention))
  end

  test "rejects identifier-shaped customer metadata in programme role and operation identity" do
    base = event("e1", 1, "task_accepted")
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:identity][:programme], "Customer_Jane_Doe_medical_diagnosis"))
    assert {:error, :malformed_data} = EventContract.new(put_in(base.data[:sender][:role], "Customer_Jane_Doe_medical_diagnosis"))
    bad = base |> put_in([:data, :identity, :idempotency], "Customer_Jane_Doe_medical_diagnosis") |> put_in([:data, :delivery, :idempotency_key], "Customer_Jane_Doe_medical_diagnosis")
    assert {:error, :malformed_data} = EventContract.new(bad)
  end

  test "freezes every declared terminal snapshot against progress recovery and terminal rewrites" do
    for terminal <- ~w(cleanup_complete superseded failed cancelled complete archived dead_letter), later <- ~w(durable_progress attention failed superseded) do
      state = %EventContract.State{current: terminal}
      assert {:error, :terminal_state} = EventContract.transition(state, event("e1", 1, later))
    end
  end

  test "accepts controlled structural domains and rejects disguised prose across all generated identifiers" do
    assert {:ok, _} = EventContract.new(event("e1", 1, "task_accepted"))
    assert {:ok, _} = EventContract.new(put_in(event("e1", 1, "task_accepted").data[:identity][:programme], "programme-00000000000000000000000000000051"))

    for path <- [[:data, :identity, :task], [:data, :sender, :id], [:data, :identity, :idempotency], [:data, :delivery, :idempotency_key]] do
      assert {:error, :malformed_data} = EventContract.new(put_in(event("e1", 1, "task_accepted"), path, "Customer_Jane_Doe_medical_diagnosis"))
    end
  end
end
