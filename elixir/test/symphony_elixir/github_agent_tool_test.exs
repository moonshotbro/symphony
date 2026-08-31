defmodule SymphonyElixir.GitHub.AgentToolTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ActionLedger
  alias SymphonyElixir.GitHub.AgentTool

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  test "advertises and executes the guarded github merge boundary" do
    assert Enum.any?(AgentTool.tool_specs(), &(&1["name"] == "github_merge"))
    {ledger, path} = start_ledger()
    on_exit(fn -> stop_ledger(ledger, path) end)
    parent = self()

    request = fn method, _path, _params, body, _opts ->
      send(parent, {method, body})

      case method do
        "GET" -> {:ok, %{status: 200, body: %{"head" => %{"sha" => @head}, "base" => %{"sha" => @base}, "merged" => false}}}
        "PUT" -> {:ok, %{status: 200, body: %{"merged" => true}}}
      end
    end

    result = AgentTool.execute("github_merge", arguments(), tracker_settings: settings(), ledger: ledger, request_fun: request)
    assert result["success"]
    assert_receive {"PUT", %{"sha" => @head}}
  end

  test "does not expose a merge boundary without exact review evidence" do
    result = AgentTool.execute("github_merge", Map.put(arguments(), "review_evidence", %{}), tracker_settings: settings())
    refute result["success"]
  end

  test "reports guarded merge failures and accepts an explicit merge method" do
    {:ok, ledger} = ActionLedger.start_link(name: nil, path: Path.join(System.tmp_dir!(), "tool-disabled-#{System.unique_integer()}.jsonl"), enabled: false)
    on_exit(fn -> if Process.alive?(ledger), do: GenServer.stop(ledger) end)
    result = AgentTool.execute("github_merge", Map.put(arguments(), "merge_method", "merge"), tracker_settings: settings(), ledger: ledger)
    refute result["success"]
  end

  test "rejects malformed merge requests at the tool boundary" do
    for arguments <- [
          "not-a-map",
          Map.put(arguments(), "pull_number", 0),
          Map.put(arguments(), "required_checks", "ci"),
          Map.put(arguments(), "merge_method", "bad"),
          Map.put(arguments(), "review_evidence", "bad")
        ] do
      result = AgentTool.execute("github_merge", arguments, tracker_settings: settings())
      refute result["success"]
    end
  end

  defp arguments do
    %{
      "repository" => "octo/repo",
      "pull_number" => 7,
      "reviewed_head" => @head,
      "reviewed_base" => @base,
      "required_checks" => [],
      "purpose" => "Reviewed merge",
      "review_evidence" => %{
        "source" => "github:octo/repo#7",
        "reviewer" => "reviewer",
        "reviewed_at" => "2026-08-31T00:00:00Z",
        "head" => @head,
        "base" => @base,
        "checks" => []
      }
    }
  end

  defp settings, do: %{provider: %{"repo" => "octo/repo", "token" => "test-token"}}

  defp start_ledger do
    path = Path.join(System.tmp_dir!(), "merge-tool-ledger-#{System.unique_integer([:positive])}.jsonl")
    {:ok, ledger} = ActionLedger.start_link(name: nil, path: path)
    {ledger, path}
  end

  defp stop_ledger(ledger, path) do
    if Process.alive?(ledger), do: GenServer.stop(ledger)
    File.rm(path)
  end
end
