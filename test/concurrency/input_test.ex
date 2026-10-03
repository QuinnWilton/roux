# Concuerror test modules for Roux.Input.
#
# Each module exercises a specific concurrent race condition with 2–3
# processes. Concuerror systematically explores all scheduler interleavings
# and verifies the assertions hold in every case.
#
# Run with:
#   mix concuerror -m Roux.Concurrency.InputSetSetRaceTest
#   mix concuerror --all

defmodule Roux.Concurrency.InputSetSetRaceTest do
  @moduledoc """
  Two processes set the same input key with different values concurrently.
  Both must complete, and the final value must be one of the two values.
  """

  alias Roux.Input

  def test do
    db = make_db()

    Input.register(db, Input.define(:source))

    parent = self()

    spawn(fn ->
      Input.set(db, :source, :k, :alpha)
      send(parent, :set1_done)
    end)

    spawn(fn ->
      Input.set(db, :source, :k, :beta)
      send(parent, :set2_done)
    end)

    receive(do: (:set1_done -> :ok))
    receive(do: (:set2_done -> :ok))

    value = Input.get(db, :source, :k)

    case value do
      :alpha -> :ok
      :beta -> :ok
    end

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    input_reg = :ets.new(:input_reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: input_reg,
      input_registry: input_reg,
      task_registry: input_reg,
      dedup_table: input_reg,
      dedup_waiters: input_reg,
      intern_registry: input_reg,
      entity_registry: input_reg,
      table_owner: self(),
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.input_registry)
  end
end

defmodule Roux.Concurrency.InputSetGetRaceTest do
  @moduledoc """
  One process sets an input key while another reads it. Get must return
  either the old value or the new value, never crash or return partial data.
  """

  alias Roux.Input
  alias Roux.Input.NotSetError

  def test do
    db = make_db()

    Input.register(db, Input.define(:source))
    Input.set(db, :source, :k, :old)

    parent = self()

    spawn(fn ->
      Input.set(db, :source, :k, :new)
      send(parent, :set_done)
    end)

    spawn(fn ->
      result =
        try do
          {:ok, Input.get(db, :source, :k)}
        rescue
          NotSetError -> :miss
        end

      send(parent, {:get_result, result})
    end)

    receive(do: (:set_done -> :ok))

    result = receive(do: ({:get_result, r} -> r))

    case result do
      {:ok, :old} -> :ok
      {:ok, :new} -> :ok
    end

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    input_reg = :ets.new(:input_reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: input_reg,
      input_registry: input_reg,
      task_registry: input_reg,
      dedup_table: input_reg,
      dedup_waiters: input_reg,
      intern_registry: input_reg,
      entity_registry: input_reg,
      table_owner: self(),
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.input_registry)
  end
end

defmodule Roux.Concurrency.InputSetReaderRaceTest do
  @moduledoc """
  Two processes set the same input key while a third recomputes a stale
  reader of it. Once all three finish, the reader must return the input's
  final value: no interleaving may record an overwritten value as current
  at a revision that already holds the new one.
  """

  alias Roux.{Input, Runtime}

  def concuerror_options do
    [dpor: :source, scheduling_bound: 3, depth_bound: 5_000]
  end

  def test do
    db = make_db()
    query = fn db, key -> Runtime.input(db, :source, key) end

    Input.set(db, :source, :k, :old)
    :old = Runtime.execute(db, :reader, :k, query)
    Input.set(db, :source, :k, :stale)

    monitors =
      for run <- [
            fn -> Runtime.execute(db, :reader, :k, query) end,
            fn -> Input.set(db, :source, :k, :alpha) end,
            fn -> Input.set(db, :source, :k, :beta) end
          ] do
        {pid, ref} = spawn_monitor(run)
        {pid, ref}
      end

    for {pid, ref} <- monitors, do: receive(do: ({:DOWN, ^ref, :process, ^pid, :normal} -> :ok))

    final = Input.get(db, :source, :k)
    true = final in [:alpha, :beta]
    ^final = Runtime.execute(db, :reader, :k, query)
  end

  # The tables die with the test process: Concuerror's exit bookkeeping
  # fails on a table a scenario that runs queries deletes itself.
  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    dedup = :ets.new(:dedup, [:set, :public, write_concurrency: true])
    waiters = :ets.new(:waiters, [:duplicate_bag, :public, write_concurrency: true])
    task_reg = :ets.new(:task_reg, [:set, :public, write_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])
    :ets.insert(reg, {:source, %{durability: :low}})

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: task_reg,
      dedup_table: dedup,
      dedup_waiters: waiters,
      intern_registry: reg,
      entity_registry: reg,
      table_owner: self(),
      supervisor: self()
    }
  end
end
