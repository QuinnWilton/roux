defmodule Roux.Database.Supervisor do
  @moduledoc """
  Supervises the ETS table ownership processes.

  Uses `:rest_for_one` strategy: if `Heir` crashes, `TableOwner` restarts too
  (tables are lost — catastrophic case). If `TableOwner` crashes alone, `Heir`
  stays up to preserve tables via the ETS heir mechanism.
  """

  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_opts) do
    sup_pid = self()

    children = [
      {Roux.Database.Heir, sup_pid: sup_pid},
      {Roux.Database.TableOwner, sup_pid: sup_pid}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
