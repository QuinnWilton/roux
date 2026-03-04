# Concuerror test modules for Roux.GC.
#
# Each module exercises a specific concurrent race condition with 2-3
# processes. Concuerror systematically explores all scheduler interleavings
# and verifies the assertions hold in every case.
#
# Run with:
#   MIX_ENV=test mix concuerror -m Roux.Concurrency.GCSweepQueryRaceTest
#   MIX_ENV=test mix concuerror --all

defmodule Roux.Concurrency.GCSweepQueryRaceTest do
  @moduledoc """
  Two concurrent sweep_query calls decrementing the same entity.

  Both queries previously produced entity E (refcount=2). Both re-execute
  and no longer produce E. The two sweep_query calls race to decrement.

  Invariant: final refcount is 0, regardless of interleaving.
  """

  alias Roux.{Entity, GC}

  @sample Roux.Test.SampleEntity

  def test do
    db = make_db()
    parent = self()

    # Create entity with refcount 2 (two queries reference it).
    entity_id = Entity.create(db, @sample, %{name: :shared, body: nil, return_type: nil}, 1)
    Entity.increment_refcount(db, @sample, entity_id)
    Entity.increment_refcount(db, @sample, entity_id)

    # Process 1: sweep_query removes entity from query 1's output.
    p1 =
      spawn(fn ->
        GC.sweep_query(db, {:q, :one}, [{@sample, entity_id}], [])
        send(parent, :p1_done)
      end)

    ref1 = Process.monitor(p1)

    # Process 2: sweep_query removes entity from query 2's output.
    p2 =
      spawn(fn ->
        GC.sweep_query(db, {:q, :two}, [{@sample, entity_id}], [])
        send(parent, :p2_done)
      end)

    ref2 = Process.monitor(p2)

    # Wait for both.
    receive do
      :p1_done -> :ok
      {:DOWN, ^ref1, :process, ^p1, _} -> :ok
    end

    receive do
      :p2_done -> :ok
      {:DOWN, ^ref2, :process, ^p2, _} -> :ok
    end

    # Invariant: refcount must be exactly 0.
    0 = Entity.refcount(db, @sample, entity_id)

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    entity_reg = :ets.new(:entity_reg, [:set, :public, read_concurrency: true])

    entity_tid =
      :ets.new(@sample, [:set, :public, read_concurrency: true, write_concurrency: true])

    :ets.insert(entity_reg, {@sample, entity_tid})

    intern_reg = :ets.new(:intern_reg, [:set, :public, read_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: reg,
      dedup_table: reg,
      intern_registry: intern_reg,
      entity_registry: entity_reg,
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.entity_registry)
    :ets.delete(db.query_registry)
    :ets.delete(db.intern_registry)
  end
end

defmodule Roux.Concurrency.GCSweepSweepQueryRaceTest do
  @moduledoc """
  `sweep` racing with `sweep_query`.

  Entity E has refcount=1 (one query references it). The query re-executes
  and no longer produces E (sweep_query decrements to 0). Concurrently,
  sweep runs and scans entity tables.

  Invariant: entity is either deleted by sweep (if sweep sees refcount=0)
  or survives with refcount=0 (if sweep scans before decrement). No
  double-free or crash.
  """

  alias Roux.{Entity, GC}

  @sample Roux.Test.SampleEntity

  def test do
    db = make_db()
    parent = self()

    # Create entity with refcount 1.
    entity_id = Entity.create(db, @sample, %{name: :target, body: nil, return_type: nil}, 1)
    Entity.increment_refcount(db, @sample, entity_id)

    # Process 1: sweep_query removes entity from output.
    p1 =
      spawn(fn ->
        GC.sweep_query(db, {:q, :owner}, [{@sample, entity_id}], [])
        send(parent, :query_done)
      end)

    ref1 = Process.monitor(p1)

    # Process 2: sweep runs concurrently.
    p2 =
      spawn(fn ->
        GC.sweep(db)
        send(parent, :sweep_done)
      end)

    ref2 = Process.monitor(p2)

    # Wait for both.
    receive do
      :query_done -> :ok
      {:DOWN, ^ref1, :process, ^p1, _} -> :ok
    end

    receive do
      :sweep_done -> :ok
      {:DOWN, ^ref2, :process, ^p2, _} -> :ok
    end

    # Invariant: entity is either deleted or has refcount == 0.
    # Never a crash, never a negative refcount.
    case Entity.get_fields(db, @sample, entity_id) do
      {:ok, _fields} ->
        # Entity survived — refcount must be 0 (sweep ran before decrement,
        # or sweep didn't see refcount=0 yet).
        0 = Entity.refcount(db, @sample, entity_id)

      :error ->
        # Entity was deleted by sweep — correct.
        :ok
    end

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    entity_reg = :ets.new(:entity_reg, [:set, :public, read_concurrency: true])

    entity_tid =
      :ets.new(@sample, [:set, :public, read_concurrency: true, write_concurrency: true])

    :ets.insert(entity_reg, {@sample, entity_tid})

    intern_reg = :ets.new(:intern_reg, [:set, :public, read_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: reg,
      dedup_table: reg,
      intern_registry: intern_reg,
      entity_registry: entity_reg,
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.entity_registry)
    :ets.delete(db.query_registry)
    :ets.delete(db.intern_registry)
  end
end
