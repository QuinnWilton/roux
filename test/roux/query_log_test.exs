defmodule Roux.QueryLogTest do
  use ExUnit.Case, async: true

  alias Roux.{Database, Input, QueryLog, Runtime}

  setup do
    db = Database.new()
    Database.register_input(db, :src, durability: :medium)
    on_exit(fn -> quietly(fn -> Database.shutdown(db) end) end)
    %{db: db}
  end

  defp quietly(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  defp length_of(db, key) do
    Runtime.execute(db, :len, key, fn db, key -> db |> Runtime.input(:src, key) |> byte_size() end)
  end

  defp parity(db, key) do
    Runtime.execute(db, :parity, key, fn db, key -> rem(length_of(db, key), 2) end)
  end

  test "records executions, hits and cutoffs of its database", %{db: db} do
    Input.set(db, :src, "a", "xy")
    Input.set(db, :src, "b", "xyz")
    log = QueryLog.start(db)

    parity(db, "a")
    parity(db, "b")
    assert QueryLog.executions(log, :parity) == ["a", "b"]
    assert QueryLog.executions(log, :len) == ["a", "b"]

    QueryLog.reset(log)
    Input.set(db, :src, "a", "wxyz")
    parity(db, "a")
    parity(db, "b")

    # "a" re-ran and came back even again; "b" was served as it was.
    assert QueryLog.executions(log, :len) == ["a"]
    assert QueryLog.executions(log, :parity) == ["a"]
    assert QueryLog.cutoffs(log, :parity) == ["a"]
    assert QueryLog.hits(log, :parity) == ["b"]
    assert QueryLog.by_query(log, :execution) == %{len: ["a"], parity: ["a"]}

    QueryLog.stop(log)
  end

  test "sees nothing of another database", %{db: db} do
    other = Database.new()
    Database.register_input(other, :src, durability: :medium)
    Input.set(db, :src, "a", "x")
    Input.set(other, :src, "b", "x")

    mine = QueryLog.start(db)
    every = QueryLog.start(:all)

    try do
      parity(db, "a")
      parity(other, "b")

      assert QueryLog.executions(mine, :parity) == ["a"]
      assert QueryLog.executions(every, :parity) == ["a", "b"]
    after
      QueryLog.stop(mine)
      QueryLog.stop(every)
      Database.shutdown(other)
    end
  end

  test "stops from another process, after the one that started it exited", %{db: db} do
    Input.set(db, :src, "a", "x")

    log =
      fn -> QueryLog.start(db) end
      |> Task.async()
      |> Task.await()

    parity(db, "a")
    assert QueryLog.executions(log, :parity) == ["a"]

    assert QueryLog.stop(log) == :ok
    refute Process.alive?(log.owner)
    assert QueryLog.stop(log) == :ok

    # Detached: a query after the stop reaches no handler of the log.
    assert Enum.all?(:telemetry.list_handlers([:roux, :query, :start]), &(&1.id != log.handler))
  end
end
