defmodule Roux.RestoreNewTest do
  use ExUnit.Case, async: true

  alias Roux.{Database, Dependencies, Input, Memo, QueryLog, Revision, Runtime}

  defp database do
    db = Database.new()
    Input.register(db, Input.define(:source))
    Database.register_query(db, :leaf, %{code_version: "leaf-v1"})
    Database.register_query(db, :root, %{})
    on_exit(fn -> stop(db) end)
    db
  end

  defp leaf(db, key) do
    Runtime.execute(db, :leaf, key, fn db, _ -> Runtime.input(db, :source, :all) end)
  end

  defp root(db) do
    Runtime.execute(db, :root, :all, fn db, _ ->
      for key <- 1..600, reduce: 0, do: (sum -> sum + leaf(db, key))
    end)
  end

  test "bulk restoration keeps every edge across batches and validates before reuse" do
    original = database()
    Input.set(original, :source, :all, 2)
    assert root(original) == 1200
    saved = Memo.persisted(original, fn _, _ -> true end)
    restored = database()
    Revision.restore(restored.revision, Revision.snapshot(original.revision))

    # Registration can leave dirty code keys in a fresh session. Those are not
    # memo publications and must not disqualify the unpublished restore path.
    assert :ets.info(restored.dependencies.dirty, :size) > 0
    assert Memo.restore_new(restored, saved) == :ok
    assert :ets.info(restored.memo_table, :size) == length(saved)
    assert :ets.info(restored.dependencies.nodes, :size) == length(saved)
    assert :ets.info(restored.dependencies.edges, :size) == 1200
    assert Dependencies.status(restored, {:root, :all}) == :check

    log = QueryLog.start(restored)

    try do
      assert root(restored) == 1200
      assert QueryLog.executions(log, :root) == []
      assert QueryLog.executions(log, :leaf) == []
      assert Dependencies.status(restored, {:root, :all}) == :clean
      Input.set(restored, :source, :all, 3)
      assert Dependencies.status(restored, {:root, :all}) == :check
      assert root(restored) == 1800
      assert Dependencies.status(restored, {:root, :all}) == :clean
      assert :ets.info(restored.dependencies.edges, :size) == 1200
    after
      QueryLog.stop(log)
    end
  end

  test "bulk restoration rejects populated databases while public restoration replaces safely" do
    db = database()
    Input.set(db, :source, :all, 2)
    assert leaf(db, {:_, :"$1"}) == 2
    saved = Memo.persisted(db, fn _, _ -> true end)

    assert_raise ArgumentError, ~r/empty memo table/, fn -> Memo.restore_new(db, saved) end
    assert Memo.restore_persisted(db, saved) == :ok
    assert Memo.restore_persisted(db, saved) == :ok
    assert :ets.info(db.dependencies.edges, :size) == 1
    Input.set(db, :source, :all, 3)
    assert leaf(db, {:_, :"$1"}) == 3
  end

  test "invalid or duplicated rows do not publish a partial fresh index" do
    original = database()
    Input.set(original, :source, :all, 2)
    assert leaf(original, :all) == 2
    [entry | _] = saved = Memo.persisted(original, fn _, _ -> true end)
    fresh = database()

    for malformed <- [saved ++ [:invalid], saved ++ [entry]] do
      assert_raise ArgumentError, fn -> Memo.restore_new(fresh, malformed) end
      assert :ets.info(fresh.memo_table, :size) == 0
      assert :ets.info(fresh.dependencies.nodes, :size) == 0
      assert :ets.info(fresh.dependencies.edges, :size) == 0
    end

    assert Memo.restore_new(fresh, saved) == :ok
  end

  defp stop(db) do
    Database.shutdown(db)
  catch
    :exit, _ -> :ok
  end
end
