defmodule Mix.Tasks.Toscanini.Capabilities do
  @shortdoc "Print the bounded Toscanini control-plane capabilities"
  @moduledoc "Prints the deterministic, non-MCP Toscanini interface as JSON."

  use Mix.Task

  alias SymphonyElixir.Toscanini.ControlPlane

  @spec run([String.t()]) :: :ok
  def run([]) do
    IO.puts(Jason.encode!(ControlPlane.capabilities()))
  end

  def run(_args) do
    Mix.raise("usage: mix toscanini.capabilities")
  end
end
