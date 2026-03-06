defmodule Roux.GC do
  @moduledoc """
  Garbage collection of stale memo entries and dead entities.

  Without GC, a long-running server accumulates unbounded dead state in ETS
  tables over hundreds of edits. Elixir's garbage collector handles process
  heap data, but ETS entries persist until explicitly deleted.

  ## Entry points

  - `sweep/1` — periodic sweep deleting zero-refcount entities and orphaned
    memo entries. Run on idle or explicit trigger, never during active query
    execution.
  - `sweep_query/4` — called by Runtime after a query re-executes to diff
    output entities and adjust refcounts.
  - `mark_input_removed/3` — called when an input is removed (e.g. file
    deleted). Deletes the memo entry and advances the revision counter.
  """

  alias Roux.{Database, Entity, Memo, Revision, Telemetry}
  alias Roux.Memo.Entry

  @type sweep_result :: %{
          memo_entries_removed: non_neg_integer(),
          entities_removed: non_neg_integer(),
          duration_us: non_neg_integer()
        }

  # -- Public API -------------------------------------------------------------

  @doc """
  Performs a garbage collection sweep.

  Deletes all entities with refcount == 0, then cascades to delete orphaned
  memo entries (entries where any dependency's memo entry is missing).

  Returns statistics about what was cleaned. Emits `[:roux, :gc, :sweep]`
  telemetry.

  Must not run while any query is in a fixed-point iteration loop.
  """
  @spec sweep(Database.t()) :: sweep_result()
  def sweep(%Database{} = db) do
    start = System.monotonic_time(:microsecond)

    entities_removed = sweep_entities(db)
    memo_entries_removed = sweep_orphaned_memo_entries(db)

    duration_us = System.monotonic_time(:microsecond) - start
    revision = Revision.current(db.revision)
    Telemetry.gc_sweep(duration_us, memo_entries_removed, entities_removed, revision)

    %{
      memo_entries_removed: memo_entries_removed,
      entities_removed: entities_removed,
      duration_us: duration_us
    }
  end

  @doc """
  Diffs a query's output entities after re-execution.

  Decrements refcounts for entities in `old` but not `new`.
  Increments refcounts for entities in `new` but not `old`.

  Resilient to entities that have already been deleted by a prior sweep —
  `Entity.decrement_refcount/3` raises `ArgumentError` on missing entities,
  which is rescued here.

  ## Options

    * `:old` — entities from the previous execution (required)
    * `:new` — entities from the current execution (required)
  """
  @spec sweep_query(
          Database.t(),
          Memo.query_key(),
          keyword()
        ) :: :ok
  def sweep_query(%Database{} = db, _query_key, opts) do
    old_entities = Keyword.fetch!(opts, :old)
    new_entities = Keyword.fetch!(opts, :new)

    removed = old_entities -- new_entities
    added = new_entities -- old_entities

    Enum.each(removed, fn {module, entity_id} ->
      try do
        Entity.decrement_refcount(db, module, entity_id)
      rescue
        # Entity was deleted by a prior sweep.
        ArgumentError -> :ok
      end
    end)

    Enum.each(added, fn {module, entity_id} ->
      Entity.increment_refcount(db, module, entity_id)
    end)

    :ok
  end

  @doc """
  Marks an input as removed (e.g. file deleted).

  Deletes the input's memo entry and advances the revision counter so
  downstream queries detect the change on next validation. No-op if the
  input was never set.
  """
  @spec mark_input_removed(Database.t(), atom(), term()) :: :ok
  def mark_input_removed(%Database{} = db, input_name, key) when is_atom(input_name) do
    query_key = {:input, input_name, key}

    case Memo.get(db, query_key) do
      {:ok, %Entry{durability: durability}} ->
        Memo.delete(db, query_key)
        Revision.advance(db.revision, durability)
        :ok

      :miss ->
        :ok
    end
  end

  # -- Private helpers --------------------------------------------------------

  # Scans all entity tables for entities with refcount == 0 and deletes them.
  defp sweep_entities(%Database{} = db) do
    db.entity_registry
    |> :ets.tab2list()
    |> Enum.reduce(0, fn {module, tid}, acc ->
      # Entity ETS rows are {entity_id, fields_map, refcount}.
      # Match refcount == 0 at position 3.
      dead_ids = :ets.match(tid, {:"$1", :_, 0})

      Enum.each(dead_ids, fn [entity_id] ->
        Entity.delete(db, module, entity_id)
      end)

      acc + length(dead_ids)
    end)
  end

  # Cascades orphaned memo entry deletion to fixed-point.
  #
  # A memo entry is orphaned when it has non-empty dependencies and at least
  # one dependency's memo entry is missing. Deleting orphaned entries may
  # orphan further entries, so we loop until no more are found.
  defp sweep_orphaned_memo_entries(db) do
    sweep_orphaned_memo_entries(db, 0)
  end

  defp sweep_orphaned_memo_entries(db, acc) do
    orphaned =
      db
      |> Memo.entries()
      |> Enum.filter(fn {_key, entry} ->
        entry.dependencies != [] and
          Enum.any?(entry.dependencies, fn dep -> Memo.get(db, dep) == :miss end)
      end)

    if orphaned == [] do
      acc
    else
      Enum.each(orphaned, fn {key, _entry} -> Memo.delete(db, key) end)
      # Cascade: deleting these may orphan others.
      sweep_orphaned_memo_entries(db, acc + length(orphaned))
    end
  end
end
