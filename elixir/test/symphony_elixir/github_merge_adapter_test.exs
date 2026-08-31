defmodule SymphonyElixir.GitHub.MergeAdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ActionLedger
  alias SymphonyElixir.GitHub.MergeAdapter
  alias SymphonyElixir.GitHub.MergeAdapter.Intent
  alias SymphonyElixir.GitHub.MergeAdapter.ReviewEvidence

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  test "requires an exact reviewed head and base" do
    intent = intent()
    assert :ok = MergeAdapter.validate_intent(intent)
    assert {:error, :invalid_reviewed_head} = MergeAdapter.validate_intent(%{intent | reviewed_head: "head"})
    assert {:error, :invalid_reviewed_base} = MergeAdapter.validate_intent(%{intent | reviewed_base: "base"})
  end

  test "rejects malformed intent fields" do
    checks = [
      {%{repository: "bad"}, :invalid_repository},
      {%{pull_number: 0}, :invalid_pull_number},
      {%{reviewed_head: "bad"}, :invalid_reviewed_head},
      {%{reviewed_base: "bad"}, :invalid_reviewed_base},
      {%{required_checks: [42]}, :invalid_required_checks},
      {%{purpose: ""}, :invalid_purpose},
      {%{merge_method: "bad"}, :invalid_merge_method},
      {%{intent_key: ""}, :invalid_intent_key}
    ]

    Enum.each(checks, fn {changes, error} ->
      assert {:error, ^error} = MergeAdapter.validate_intent(struct!(intent(), changes))
    end)
  end

  test "fails closed when configured repository cannot be established" do
    assert {:error, {:repository_scope_unavailable, :missing_github_repo}} =
             MergeAdapter.merge(intent())
  end

  test "fails closed when the action ledger cannot plan" do
    {:ok, ledger} = ActionLedger.start_link(name: nil, path: Path.join(System.tmp_dir!(), "disabled-#{System.unique_integer()}.jsonl"), enabled: false)
    on_exit(fn -> if Process.alive?(ledger), do: GenServer.stop(ledger) end)

    assert {:error, {:merge_ledger_plan_failed, :action_ledger_disabled}} =
             MergeAdapter.merge(intent(), tracker_settings: settings(), ledger: ledger)
  end

  test "rejects a repository outside the configured tracker scope before planning" do
    request = fn _method, _path, _params, _body, _opts -> raise "provider must not be called" end

    assert {:error, :repository_scope_mismatch} =
             MergeAdapter.merge(intent(),
               tracker_settings: %{provider: %{"repo" => "other/repo"}},
               request_fun: request
             )
  end

  test "accepts supported ledger server references and falls back safely for invalid references" do
    ledger_path = Path.join(System.tmp_dir!(), "merge-global-ledger-#{System.unique_integer()}.jsonl")
    {:ok, global_ledger} = ActionLedger.start_link(name: ActionLedger, path: ledger_path)

    on_exit(fn ->
      if Process.alive?(global_ledger), do: GenServer.stop(global_ledger)
      File.rm(ledger_path)
    end)

    for ledger_reference <- [ActionLedger, {ActionLedger, node()}, 42] do
      result =
        MergeAdapter.merge(intent(),
          ledger: ledger_reference,
          tracker_settings: settings(),
          request_fun: fn _method, _path, _params, _body, _opts -> {:ok, %{status: 404}} end
        )

      assert match?({:error, _}, result)
    end
  end

  test "requires privacy-bounded evidence for the exact reviewed head" do
    assert {:error, :invalid_review_evidence} =
             MergeAdapter.validate_intent(%{intent() | review_evidence: nil})

    stale = %ReviewEvidence{evidence() | head: String.duplicate("c", 40)}
    assert {:error, :invalid_review_evidence} = MergeAdapter.validate_intent(%{intent() | review_evidence: stale})
  end

  test "binds review evidence to the exact repository and pull request" do
    assert :ok = MergeAdapter.validate_intent(intent())

    for source <- ["github:evil/repo#7", "github:octo/repo#8", "github:octo/repo", "github:octo/repo#0"] do
      evidence = %{evidence() | source: source}
      assert {:error, :invalid_review_evidence} = MergeAdapter.validate_intent(%{intent() | review_evidence: evidence})
    end
  end

  test "rejects invalid review timestamp and check evidence" do
    assert {:error, :invalid_review_evidence} =
             MergeAdapter.validate_intent(%{intent() | review_evidence: %{evidence() | reviewed_at: "yesterday"}})

    assert {:error, :invalid_review_evidence} =
             MergeAdapter.validate_intent(%{intent() | review_evidence: %{evidence() | checks: :unknown}})

    assert {:error, :invalid_review_evidence} =
             MergeAdapter.validate_intent(%{intent() | review_evidence: %{evidence() | reviewed_at: nil}})
  end

  test "submits GitHub expected-head merge once and records the outcome" do
    {ledger, path} = start_ledger()
    on_exit(fn -> stop_ledger(ledger, path) end)
    parent = self()

    request = fn method, path_name, _params, body, _opts ->
      send(parent, {:request, method, path_name, body})

      case method do
        "GET" -> {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}}}}
        "PUT" -> {:ok, %{status: 200, body: %{"merged" => true, "sha" => @head}}}
      end
    end

    assert {:ok, :merged, _} = MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request)
    assert_receive {:request, "PUT", "/repos/octo/repo/pulls/7/merge", %{"sha" => @head, "merge_method" => "squash"}}

    assert {:ok, :already_satisfied, %{disposition: "duplicate_suppressed"}} =
             MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request, telemetry_fun: fn _event, _measure, _metadata -> raise "telemetry unavailable" end)

    refute_receive {:request, "PUT", "/repos/octo/repo/pulls/7/merge", _}
  end

  test "stale reviewed heads are held and routed to fresh review" do
    {ledger, path} = start_ledger()
    on_exit(fn -> stop_ledger(ledger, path) end)
    parent = self()

    request = fn "GET", _path, _params, _body, _opts ->
      send(parent, :read)
      {:ok, %{status: 200, body: %{"head" => %{"sha" => String.duplicate("c", 40)}, "base" => %{"sha" => @base}}}}
    end

    assert {:error, :stale_source} = MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request, review_router: fn reason -> send(parent, {:route, reason}) end)
    assert_receive {:route, :stale_source}
    assert {:ok, action} = ActionLedger.get(ledger, action_id(ledger))
    assert action.state == :needs_input
    assert action.observed_effect["disposition"] == "fresh_review_required"
  end

  test "recognizes an already merged pull request" do
    {ledger, path} = start_ledger()
    on_exit(fn -> stop_ledger(ledger, path) end)

    request = fn "GET", _path, _params, _body, _opts ->
      {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => true}}}
    end

    assert {:ok, :already_satisfied, %{disposition: "already_merged"}} =
             MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request, telemetry_fun: fn _event, _measure, _metadata -> raise "telemetry unavailable" end)
  end

  test "suppresses a second merge while the first action is in flight" do
    {ledger, path} = start_ledger()
    on_exit(fn -> stop_ledger(ledger, path) end)
    parent = self()

    request = fn
      "GET", _path, _params, _body, _opts ->
        send(parent, :first_read)

        receive do
          :release -> {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
        end

      "PUT", _path, _params, _body, _opts ->
        {:ok, %{status: 200, body: %{"merged" => true}}}
    end

    task = Task.async(fn -> MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request) end)
    assert_receive :first_read
    assert {:error, {:duplicate_in_flight, _}} = MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request)
    send(task.pid, :release)
    assert {:ok, :merged, _} = Task.await(task)
  end

  test "handles provider status, transport, and check-read failures" do
    for result <- [{:ok, %{status: 409}}, {:ok, %{status: 500}}, {:error, :offline}, {:error, "offline"}] do
      {ledger, path} = start_ledger()
      on_exit(fn -> stop_ledger(ledger, path) end)
      request = fn _method, _path, _params, _body, _opts -> result end
      assert {:error, _} = MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request, review_router: fn _ -> :ok end)
    end

    {ledger, path} = start_ledger()
    on_exit(fn -> stop_ledger(ledger, path) end)

    request = fn "GET", path_name, _params, _body, _opts ->
      if String.contains?(path_name, "check-runs"),
        do: {:error, :check_offline},
        else: {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
    end

    checked = %{intent() | required_checks: ["ci"], review_evidence: %{evidence() | checks: ["ci"]}}
    assert {:error, _} = MergeAdapter.merge(checked, ledger: ledger, tracker_settings: settings(), request_fun: request)

    {ledger2, path2} = start_ledger()
    on_exit(fn -> stop_ledger(ledger2, path2) end)

    status_request = fn "GET", path_name, _params, _body, _opts ->
      if String.contains?(path_name, "check-runs"),
        do: {:ok, %{status: 503}},
        else: {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
    end

    assert {:error, _} = MergeAdapter.merge(checked, ledger: ledger2, tracker_settings: settings(), request_fun: status_request)

    {ledger3, path3} = start_ledger()
    on_exit(fn -> stop_ledger(ledger3, path3) end)

    checks_status_409 = fn "GET", path_name, _params, _body, _opts ->
      if String.contains?(path_name, "check-runs"),
        do: {:ok, %{status: 409}},
        else: {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
    end

    assert {:error, _} = MergeAdapter.merge(checked, ledger: ledger3, tracker_settings: settings(), request_fun: checks_status_409)

    {ledger4, path4} = start_ledger()
    on_exit(fn -> stop_ledger(ledger4, path4) end)
    checks_409 = fn _method, _path, _params, _body, _opts -> {:error, {:checks_failed, ["ci"]}} end
    assert {:error, _} = MergeAdapter.merge(intent(), ledger: ledger4, tracker_settings: settings(), request_fun: checks_409)
  end

  test "reconciles uncertain failures as absent, quarantined, or still unknown" do
    evidence = %{provider: "github", authoritative: true, exists: false}

    recoveries = [
      fn -> {:ok, evidence} end,
      fn -> {:ok, %{provider: "github", authoritative: false, exists: false}} end,
      fn -> {:error, :offline} end
    ]

    for recovery <- recoveries do
      {ledger, path} = start_ledger()
      on_exit(fn -> stop_ledger(ledger, path) end)

      request = fn "GET", _path, _params, _body, _opts ->
        {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
      end

      assert {:error, _} =
               MergeAdapter.merge(intent(),
                 ledger: ledger,
                 tracker_settings: settings(),
                 request_fun: fn
                   "GET", p, q, b, o -> request.("GET", p, q, b, o)
                   "PUT", _p, _q, _b, _o -> {:error, {:github_api_request, :timeout}}
                 end,
                 recovery_fun: recovery
               )
    end
  end

  test "keeps an uncertain merge for an unavailable inspection and handles 5xx" do
    for put_result <- [{:ok, %{status: 500}}, {:error, :offline}] do
      {ledger, path} = start_ledger()
      on_exit(fn -> stop_ledger(ledger, path) end)

      request = fn
        "GET", _path, _params, _body, _opts ->
          {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}

        "PUT", _path, _params, _body, _opts ->
          put_result
      end

      assert {:error, _} = MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request, recovery_fun: fn -> {:error, :inspection_offline} end)
    end
  end

  test "handles invalid and unavailable postcondition inspections" do
    for recovery <- [fn -> {:ok, %{provider: "github", authoritative: true, exists: true, unexpected: "x"}} end, nil] do
      {ledger, path} = start_ledger()
      on_exit(fn -> stop_ledger(ledger, path) end)
      calls = Agent.start_link(fn -> 0 end) |> elem(1)

      base_request = fn "GET", _path, _params, _body, _opts ->
        case Agent.get_and_update(calls, fn count -> {count, count + 1} end) do
          0 -> {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
          _ -> {:error, :inspection_offline}
        end
      end

      request = fn
        "GET", path_name, params, body, opts -> base_request.("GET", path_name, params, body, opts)
        "PUT", _path_name, _params, _body, _opts -> {:error, {:github_api_request, :timeout}}
      end

      opts = [ledger: ledger, tracker_settings: settings(), request_fun: request]
      opts = if is_nil(recovery), do: opts, else: Keyword.put(opts, :recovery_fun, recovery)
      assert {:error, _} = MergeAdapter.merge(intent(), opts)
    end
  end

  test "holds definitive provider failures and check failures" do
    {ledger, path} = start_ledger()
    on_exit(fn -> stop_ledger(ledger, path) end)

    assert {:error, {:error, {:github_api_status, 404}}} =
             MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: fn _m, _p, _q, _b, _o -> {:ok, %{status: 404}} end)

    {ledger2, path2} = start_ledger()
    on_exit(fn -> stop_ledger(ledger2, path2) end)

    request = fn "GET", path_name, _params, _body, _opts ->
      if String.contains?(path_name, "check-runs"),
        do: {:ok, %{status: 200, body: %{"check_runs" => [%{"name" => "ci", "conclusion" => "failure"}]}}},
        else: {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
    end

    assert {:error, {:error, {:checks_failed, _}}} =
             MergeAdapter.merge(%{intent() | required_checks: ["ci"], review_evidence: %{evidence() | checks: ["ci"]}}, ledger: ledger2, tracker_settings: settings(), request_fun: request)
  end

  test "routes definitive merge rejection, conflict, and postcondition errors" do
    Enum.each([{:ok, %{status: 400}}, {:ok, %{status: 409}}, {:ok, %{status: 200, body: %{"message" => "rejected"}}}, {:ok, %{status: 200, body: %{}}}], fn put_result ->
      {ledger, path} = start_ledger()
      on_exit(fn -> stop_ledger(ledger, path) end)

      request = fn method, _path, _params, _body, _opts ->
        case method do
          "GET" -> {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
          "PUT" -> put_result
        end
      end

      result = MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request, review_router: fn _ -> :ok end)
      assert match?({:error, _}, result)
    end)
  end

  test "recovers a lost merge response from authoritative GitHub state" do
    {ledger, path} = start_ledger()
    on_exit(fn -> stop_ledger(ledger, path) end)
    parent = self()
    reads = Agent.start_link(fn -> 0 end) |> elem(1)

    request = fn method, _path, _params, body, _opts ->
      send(parent, {:request, method, body})

      case method do
        "GET" ->
          case Agent.get_and_update(reads, fn count -> {count, count + 1} end) do
            0 -> {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
            _ -> {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => true}}}
          end

        "PUT" ->
          {:error, {:github_api_request, :timeout}}
      end
    end

    assert {:ok, :already_satisfied, %{disposition: "recovered_after_uncertain_merge"}} =
             MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request)

    assert_receive {:request, "PUT", _}
    assert {:ok, %{actions: [action]}} = ActionLedger.inspect_storage(path)
    assert action.state == :already_satisfied
    assert action.observed_effect["disposition"] == "provider_postcondition_confirmed"
  end

  test "does not settle a lost merge when GitHub reports a different merged revision" do
    {ledger, path} = start_ledger()
    on_exit(fn -> stop_ledger(ledger, path) end)
    reads = Agent.start_link(fn -> 0 end) |> elem(1)
    different_head = String.duplicate("c", 40)

    request = fn method, _path, _params, _body, _opts ->
      case method do
        "GET" ->
          case Agent.get_and_update(reads, fn count -> {count, count + 1} end) do
            0 -> {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
            _ -> {:ok, %{status: 200, body: %{"head" => %{"sha" => different_head}, "base" => %{"sha" => @base}, "merged" => true}}}
          end

        "PUT" ->
          {:error, {:github_api_request, :timeout}}
      end
    end

    assert {:error, {:github_api_request, :timeout}} =
             MergeAdapter.merge(intent(), ledger: ledger, tracker_settings: settings(), request_fun: request)

    assert {:ok, %{actions: [action]}} = ActionLedger.inspect_storage(path)
    assert action.state == :quarantined
    assert action.observed_effect["disposition"] == "inspection_not_authoritative"
  end

  defp intent, do: %Intent{repository: "octo/repo", pull_number: 7, reviewed_head: @head, reviewed_base: @base, required_checks: [], purpose: "Reviewed merge", review_evidence: evidence()}
  defp evidence, do: %ReviewEvidence{source: "github:octo/repo#7", reviewer: "reviewer", reviewed_at: "2026-08-31T00:00:00Z", head: @head, base: @base, checks: []}
  defp settings, do: %{provider: %{"repo" => "octo/repo", "token" => "test-token"}}

  defp start_ledger do
    path = Path.join(System.tmp_dir!(), "merge-ledger-#{System.unique_integer([:positive])}.jsonl")
    {:ok, ledger} = ActionLedger.start_link(name: nil, path: path)
    {ledger, path}
  end

  defp stop_ledger(ledger, path) do
    if Process.alive?(ledger), do: GenServer.stop(ledger)
    File.rm(path)
  end

  defp action_id(ledger) do
    ledger
    |> ActionLedger.reconcile()
    |> Map.values()
    |> List.flatten()
    |> hd()
    |> Map.fetch!(:id)
  end
end
