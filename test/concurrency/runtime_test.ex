# Concuerror test modules for Roux.Runtime.
#
# Each module exercises a specific concurrent race condition with 2–3
# processes. Concuerror systematically explores all scheduler interleavings
# and verifies the assertions hold in every case.
#
# Run with:
#   MIX_ENV=test mix concuerror -m Roux.Concurrency.RuntimeDedupTest
#   MIX_ENV=test mix concuerror --all

defmodule Roux.Concurrency.RuntimeDedupTest do
  @moduledoc """
  Two processes request the same uncomputed query concurrently.
  Both must receive the correct value. The query function runs
  at most once per process that claims the dedup slot.
  """

  alias Roux.{Memo, Runtime}

  def concuerror_options do
    [treat_as_normal: [:shutdown]]
  end

  def test do
    db = make_db()
    parent = self()

    fun = fn _db, _key -> :result end

    spawn(fn ->
      value = Runtime.execute(db, :q, :k, fun)
      send(parent, {:r1, value})
    end)

    spawn(fn ->
      value = Runtime.execute(db, :q, :k, fun)
      send(parent, {:r2, value})
    end)

    r1 = receive(do: ({:r1, r} -> r))
    r2 = receive(do: ({:r2, r} -> r))

    # Both processes must see the correct result.
    :result = r1
    :result = r2

    # Exactly one memo entry exists with the correct value.
    {:ok, entry} = Memo.get(db, {:q, :k})
    :result = entry.value

    # Dedup table must be clean (no stale entries).
    [] = :ets.lookup(db.dedup_table, {:q, :k})

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    dedup = :ets.new(:dedup, [:set, :public, write_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: reg,
      dedup_table: dedup,
      intern_registry: reg,
      entity_registry: reg,
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.dedup_table)
    :ets.delete(db.input_registry)
  end
end

defmodule Roux.Concurrency.RuntimeDedupCompletionRaceTest do
  @moduledoc """
  One process computes a query while another requests the same query
  after computation begins. The second process must either wait for
  the first or compute fresh — it must never miss the result.
  """

  alias Roux.{Memo, Runtime}

  def concuerror_options do
    [treat_as_normal: [:shutdown]]
  end

  def test do
    db = make_db()
    parent = self()

    fun = fn _db, _key -> :value end

    # First process starts computing.
    spawn(fn ->
      Runtime.execute(db, :q, :k, fun)
      send(parent, :p1_done)
    end)

    # Second process requests the same query — may arrive before, during,
    # or after the first process completes.
    spawn(fn ->
      result = Runtime.execute(db, :q, :k, fun)
      send(parent, {:p2_result, result})
    end)

    receive(do: (:p1_done -> :ok))
    result = receive(do: ({:p2_result, r} -> r))

    # Second process must have received the correct result.
    :value = result

    # Memo must contain the correct entry.
    {:ok, entry} = Memo.get(db, {:q, :k})
    :value = entry.value

    # Dedup table must be clean.
    [] = :ets.lookup(db.dedup_table, {:q, :k})

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    dedup = :ets.new(:dedup, [:set, :public, write_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: reg,
      dedup_table: dedup,
      intern_registry: reg,
      entity_registry: reg,
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.dedup_table)
    :ets.delete(db.input_registry)
  end
end

defmodule Roux.Concurrency.RuntimeWriteBufferingTest do
  @moduledoc """
  A process crashes (raises) during query computation. The memo table
  must not contain any partial state, and the dedup table must be clean.
  """

  alias Roux.{Memo, Runtime}

  def concuerror_options do
    [treat_as_normal: [:shutdown, :killed]]
  end

  def test do
    db = make_db()
    parent = self()
    query_key = {:crash_query, :k}

    # A process that crashes during computation.
    spawn(fn ->
      try do
        Runtime.execute(db, :crash_query, :k, fn _db, _key ->
          raise "boom"
        end)
      rescue
        RuntimeError -> :ok
      end

      send(parent, :done)
    end)

    receive(do: (:done -> :ok))

    # No memo entry should exist — the crash prevented the write.
    :miss = Memo.get(db, query_key)

    # Dedup table must be clean.
    [] = :ets.lookup(db.dedup_table, query_key)

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    dedup = :ets.new(:dedup, [:set, :public, write_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: reg,
      dedup_table: dedup,
      intern_registry: reg,
      entity_registry: reg,
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.dedup_table)
    :ets.delete(db.input_registry)
  end
end
