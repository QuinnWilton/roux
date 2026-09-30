defmodule Roux.Concurrency.BoundaryRaceTest do
  @moduledoc "Two callers share one outcome when completion races the query deadline."

  alias Roux.{Database, Memo, Runtime}
  alias Roux.Test.GroupFixture

  defmodule Queries do
    @moduledoc false
    use Roux.Query

    defquery :bounded, key: key, timeout: 0, on_timeout: &__MODULE__.fallback/2 do
      _ = key
      :success
    end

    def fallback(_db, _key), do: :timeout
  end

  def concuerror_options do
    [
      treat_as_normal: [:shutdown, :killed],
      depth_bound: 5_000,
      dpor: :source,
      scheduling_bound: 3
    ]
  end

  def test do
    db = GroupFixture.stale_fan_out([])

    Database.register_query(db, :bounded, %{
      module: Queries,
      function: :bounded,
      boundary: {Queries, :__roux_boundary_bounded__, :__roux_timeout_bounded__}
    })

    parent = self()

    for tag <- [:one, :two] do
      spawn(fn -> send(parent, {tag, Runtime.query(db, :bounded, :key)}) end)
    end

    result = receive do: ({:one, value} -> value)
    ^result = receive do: ({:two, value} -> value)
    true = result in [:success, :timeout]
    {:ok, %{value: ^result}} = Memo.get(db, {:bounded, :key})
    [] = :ets.tab2list(db.dedup_table)
    [] = :ets.tab2list(db.dedup_waiters)
    [] = for {_, pid} <- :ets.tab2list(db.task_registry), is_pid(pid), do: pid
    GroupFixture.cleanup(db)
  end
end
