defmodule Roux.Test.ReverseDependencyRace do
  @moduledoc """
  An input write races a cached derived query. Once both finish, a new demand
  must return the current input and establish a clean certificate.
  """

  alias Roux.{Database, Dependencies, Input, Revision, Runtime}

  # Concuerror currently aborts on ets:update_counter/4 and also lacks
  # ets:select_replace/2. Keep this outside Roux.Concurrency until the checker
  # supports both; ExUnit exercises the real implementation repeatedly.
  def concuerror_options do
    [dpor: :source, scheduling_bound: 2, depth_bound: 2000, treat_as_normal: [:shutdown]]
  end

  def test do
    {db, tables} = make_db()

    try do
      race(db)
    after
      Runtime.drop_cached_values(db)
      Enum.each(tables, &:ets.delete/1)
    end
  end

  defp race(db) do
    Input.register(db, Input.define(:source))
    Input.set(db, :source, :a, 1)
    query = fn db, key -> Runtime.input(db, :source, key) end
    1 = Runtime.execute(db, :read, :a, query)
    parent = self()

    spawn(fn ->
      Input.set(db, :source, :a, 2)
      send(parent, :input_written)
    end)

    spawn(fn ->
      value = Runtime.execute(db, :read, :a, query)
      true = value in [1, 2]
      send(parent, :query_finished)
    end)

    receive do
      :input_written -> :ok
    end

    receive do
      :query_finished -> :ok
    end

    2 = Runtime.execute(db, :read, :a, query)
    :clean = Dependencies.status(db, {:read, :a})
  end

  defp make_db do
    tables =
      Map.new(
        [
          memo: :set,
          registry: :set,
          input_registry: :set,
          task_registry: :set,
          dedup: :set,
          waiters: :duplicate_bag,
          entity_registry: :set,
          dependency_edges: :bag,
          dependency_nodes: :set,
          dependency_dirty: :set,
          dependency_writers: :set
        ],
        fn {name, type} -> {name, :ets.new(name, [type, :public])} end
      )

    db = %Database{
      memo_table: tables.memo,
      revision: Revision.new(track_unknown: true),
      query_registry: tables.registry,
      input_registry: tables.input_registry,
      task_registry: tables.task_registry,
      dedup_table: tables.dedup,
      dedup_waiters: tables.waiters,
      intern_registry: tables.registry,
      entity_registry: tables.entity_registry,
      dependencies: Dependencies.new(tables),
      table_owner: self(),
      supervisor: self()
    }

    {db, Map.values(tables)}
  end
end
