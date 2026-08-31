defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)

    configured_ledger = SymphonyElixir.Config.settings!().action_ledger
    ledger_enabled = Keyword.get(opts, :action_ledger_enabled, configured_ledger.enabled)
    ledger_name = Keyword.get(opts, :action_ledger_name, SymphonyElixir.ActionLedger)

    ledger_path =
      Keyword.get_lazy(opts, :action_ledger_path, &SymphonyElixir.Config.local_action_ledger_path/0)

    ledger_children =
      if ledger_enabled do
        [
          Supervisor.child_spec(
            {SymphonyElixir.ActionLedger, name: ledger_name, path: ledger_path, enabled: true},
            id: ledger_name
          )
        ]
      else
        []
      end

    orchestrator_opts = [
      name: orchestrator_name,
      task_supervisor: task_supervisor_name,
      action_ledger: if(ledger_enabled, do: ledger_name, else: nil)
    ]

    orchestrator_opts =
      case Keyword.get(opts, :action_inspector) do
        inspector when is_function(inspector, 1) -> Keyword.put(orchestrator_opts, :action_inspector, inspector)
        _ -> orchestrator_opts
      end

    children =
      [
        Supervisor.child_spec(
          {Task.Supervisor, name: task_supervisor_name},
          id: task_supervisor_name
        )
      ] ++
        ledger_children ++
        [
          Supervisor.child_spec(
            {SymphonyElixir.Orchestrator, orchestrator_opts},
            id: orchestrator_name
          )
        ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
