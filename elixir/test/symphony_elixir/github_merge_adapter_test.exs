defmodule SymphonyElixir.GitHub.MergeAdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ActionLedger
  alias SymphonyElixir.GitHub.MergeAdapter
  alias SymphonyElixir.GitHub.MergeAdapter.Intent

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  test "requires an exact reviewed head and base" do
    intent = intent()
    assert :ok = MergeAdapter.validate_intent(intent)
    assert {:error, :invalid_reviewed_head} = MergeAdapter.validate_intent(%{intent | reviewed_head: "head"})
    assert {:error, :invalid_reviewed_base} = MergeAdapter.validate_intent(%{intent | reviewed_base: "base"})
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

    assert {:ok, :merged, _} = MergeAdapter.merge(intent(), ledger: ledger, request_fun: request)
    assert_receive {:request, "PUT", "/repos/octo/repo/pulls/7/merge", %{"sha" => @head, "merge_method" => "squash"}}

    assert {:ok, :already_satisfied, %{disposition: "duplicate_suppressed"}} =
             MergeAdapter.merge(intent(), ledger: ledger, request_fun: request)

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

    assert {:error, :stale_source} = MergeAdapter.merge(intent(), ledger: ledger, request_fun: request, review_router: fn reason -> send(parent, {:route, reason}) end)
    assert_receive {:route, :stale_source}
    assert {:ok, action} = ActionLedger.get(ledger, action_id(ledger))
    assert action.state == :needs_input
    assert action.observed_effect["disposition"] == "fresh_review_required"
  end

  defp intent, do: %Intent{repository: "octo/repo", pull_number: 7, reviewed_head: @head, reviewed_base: @base, required_checks: [], purpose: "Reviewed merge"}

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
