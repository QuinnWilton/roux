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
