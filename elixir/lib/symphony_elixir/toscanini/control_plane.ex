defmodule SymphonyElixir.Toscanini.ControlPlane do
  @moduledoc """
  Small, deterministic boundary for Toscanini's supported Symphony operations.

  This module is deliberately a facade over existing contracts.  It does not
  schedule work, create provider clients, or introduce a second execution
  engine.  The future MCP adapter can call these same functions and therefore
  cannot silently acquire a different policy surface.
  """

  alias SymphonyElixir.Codex.{RecoveryInspector, TaskAccountabilityRegistry, TaskLaunchContract}
  alias SymphonyElixir.GitHub.MergeAdapter
  alias SymphonyElixir.Toscanini.{EventContract, LifecycleLedger}
  alias SymphonyElixir.WorkPressure

  @type result :: {:ok, term()} | {:error, term()}

  @doc "Return the bounded operations exposed to a conductor adapter."
  @spec capabilities() :: %{required(String.t()) => [String.t()]}
  def capabilities do
    %{
      "read" => ["capabilities", "roles", "compile_task", "select_work", "validate_event", "replay_events", "ledger_diagnostics"],
      "mutate" => ["dispatch_command", "record_event", "recover_task", "merge_reviewed_pull_request"]
    }
  end

  @doc "Return the canonical task-accountability role registry."
  @spec roles() :: %{required(String.t()) => term()}
  def roles, do: TaskAccountabilityRegistry.profiles()

  @doc "Compile and verify one project-bound task launch contract."
  @spec compile_task(map()) :: {:ok, TaskLaunchContract.t()} | {:error, term()}
  def compile_task(attrs) when is_map(attrs) do
    with {:ok, contract} <- TaskLaunchContract.compile(attrs), do: TaskLaunchContract.verify(contract)
  end

  def compile_task(_attrs), do: {:error, :contract_input_not_a_map}

  @doc "Compile a task from authoritative issue and workspace runtime facts."
  @spec compile_runtime_task(map(), Path.t(), keyword()) :: {:ok, TaskLaunchContract.t() | nil} | {:error, term()}
  def compile_runtime_task(issue, workspace, opts \\ []),
    do: TaskLaunchContract.from_runtime(issue, workspace, opts)

  @doc "Select bounded ready work using Symphony's deterministic pressure policy."
  @spec select_work([map()], [map()], map(), String.t()) :: result()
  def select_work(ready, active, limits, decision_revision),
    do: WorkPressure.select(ready, active, limits, decision_revision)

  @doc "Validate one command or event envelope without persisting it."
  @spec validate_envelope(term()) :: result()
  def validate_envelope(value), do: EventContract.new(value)

  @doc "Replay a bounded event sequence through the canonical lifecycle contract."
  @spec replay_events([term()], EventContract.state()) :: result()
  def replay_events(values, state \\ EventContract.initial_state()), do: LifecycleLedger.replay(values, state)

  @doc "Dispatch a validated command through the durable ledger."
  @spec dispatch_command(GenServer.server(), term(), (-> term()), keyword()) :: term()
  def dispatch_command(ledger, envelope, effect_fun, opts \\ []),
    do: LifecycleLedger.dispatch_command(ledger, envelope, effect_fun, opts)

  @doc "Record a validated factual event through the durable ledger."
  @spec record_event(GenServer.server(), term()) :: term()
  def record_event(ledger, envelope), do: LifecycleLedger.record_event(ledger, envelope)

  @doc "Inspect an uncertain task-creation effect against persisted Codex state."
  @spec recover_task(SymphonyElixir.ActionLedger.Action.t(), keyword()) :: result()
  def recover_task(action, opts \\ []), do: RecoveryInspector.inspect(action, opts)

  @doc "Merge only a reviewed, exact-head GitHub pull request."
  @spec merge_reviewed_pull_request(MergeAdapter.Intent.t(), keyword()) :: term()
  def merge_reviewed_pull_request(intent, opts \\ []), do: MergeAdapter.merge(intent, opts)

  @doc "Return unresolved durable coordination actions for operator/conductor inspection."
  @spec ledger_diagnostics(GenServer.server()) :: map()
  def ledger_diagnostics(ledger), do: LifecycleLedger.diagnostics(ledger)
end
