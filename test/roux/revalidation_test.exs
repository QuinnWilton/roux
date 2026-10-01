defmodule Roux.RevalidationTest do
  use ExUnit.Case, async: true

  alias Roux.{Database, Dependencies, Input, Lang, Memo, QueryLog, Runtime, Session}

  @moduletag :tmp_dir

  defmodule Queries do
    use Roux.Query

    definput :source
    definput :observer

    defquery :bounded,
      key: key,
      revalidate: :execute,
      timeout: 100,
      on_timeout: &__MODULE__.fallback/2 do
      case Runtime.input(db, :source, key) do
        {:blocked, value} ->
          send(Runtime.input(db, :observer, :all), {:started, self()})

          receive do
            :finish -> value
          end

        value ->
          value
      end
    end

    defquery :ordinary, key: key do
      Runtime.input(db, :source, key)
    end

    defquery :compact, key: key, store: :blob, revalidate: :execute do
      Runtime.input(db, :source, key)
    end

    defquery :compact_inline, key: key, revalidate: :execute do
      Runtime.input(db, :source, key)
    end

    def fallback(db, key) do
      Runtime.input(db, :source, key)
      {:error, :timeout}
    end
  end

  setup do
    db = Database.new()
    Lang.register_module(db, Queries)
    on_exit(fn -> stop(db) end)
    %{db: db}
  end

  test "registration keeps the query policy and rejects an unknown policy", %{db: db} do
    assert Database.query_definition(db, :bounded).revalidate == :execute
    assert Database.query_definition(db, :ordinary).revalidate == :dependencies

    assert_raise ArgumentError, ~r/:revalidate must be :dependencies or :execute/, fn ->
      Code.compile_quoted(
        quote do
          defmodule InvalidRevalidationPolicy do
            use Roux.Query
            defquery :bad, key: key, revalidate: :other, do: key
          end
        end
      )
    end
  end

  test "a restored root replaces its old graph before parent validation", %{db: db} do
    for name <- [:leaf, :root, :parent] do
      Database.register_query(db, name, %{revalidate: if(name == :root, do: :execute)})
    end

    Input.set(db, :source, :all, 7)
    leaf = fn db, _ -> Runtime.input(db, :source, :all) end
    root = fn db, key -> Runtime.execute(db, :leaf, key, leaf) end
    parent = fn db, key -> {:parent, Runtime.execute(db, :root, key, root)} end
    assert Runtime.execute(db, :parent, :all, parent) == {:parent, 7}
    {:ok, changed_at} = Memo.changed_at(db, {:root, :all})
    saved = Memo.persisted(db, fn _, _ -> true end)

    restored = Database.new()
    on_exit(fn -> stop(restored) end)
    Lang.register_module(restored, Queries)

    for name <- [:leaf, :root, :parent] do
      Database.register_query(restored, name, %{revalidate: if(name == :root, do: :execute)})
    end

    Roux.Revision.restore(restored.revision, Roux.Revision.snapshot(db.revision))
    Memo.restore_persisted(restored, saved)

    # A successful external cache check returns the same value from a compact
    # input/code frontier. It does not require any old child query to be current.
    compact = fn db, _ ->
      Runtime.query_code(db, :leaf)
      Runtime.input(db, :source, :all)
    end

    Process.put({Runtime, :query_fun, :root}, compact)
    log = QueryLog.start(restored)

    try do
      assert Runtime.execute(restored, :parent, :all, fn _, _ -> flunk("parent executed") end) ==
               {:parent, 7}

      assert QueryLog.executions(log, :root) == [:all]
      assert QueryLog.cutoffs(log, :root) == [:all]
      assert Memo.changed_at(restored, {:root, :all}) == {:ok, changed_at}
      assert Dependencies.status(restored, {:leaf, :all}) == :check
      assert Dependencies.status(restored, {:root, :all}) == :clean

      assert Memo.dependencies(restored, {:root, :all}) ==
               {:ok, [{:query_code, :leaf, nil}, {:input, :source, :all}]}

      assert :ets.lookup(restored.dependencies.edges, {:leaf, :all}) == []

      assert Runtime.execute(restored, :root, :all, fn _, _ -> flunk("clean root executed") end) ==
               7

      generation = Memo.generation(restored, {:root, :all})
      Database.register_query(restored, :leaf, %{code_version: "new"})
      assert Dependencies.status(restored, {:root, :all}) == :check
      assert Runtime.execute(restored, :root, :all, compact) == 7
      assert Memo.generation(restored, {:root, :all}) != generation
    after
      QueryLog.stop(log)
    end
  end

  test "ordinary queries retain dependency validation and early cutoff", %{db: db} do
    Input.set(db, :source, :all, 1)
    leaf = fn db, _ -> rem(Runtime.input(db, :source, :all), 2) end
    root = fn db, key -> Runtime.execute(db, :leaf, key, leaf) end
    assert Runtime.execute(db, :root, :all, root) == 1
    Input.set(db, :source, :all, 3)
    assert Runtime.execute(db, :root, :all, fn _, _ -> flunk("ordinary root executed") end) == 1
  end

  for query <- [:compact, :compact_inline] do
    test "#{query} checkpoints frontier compaction once and skips unchanged later proofs", %{
      tmp_dir: dir
    } do
      opts = [
        modules: [Queries],
        manifest: Path.join(dir, "manifest"),
        blob: Path.join(dir, "store")
      ]

      first = Session.open(opts)
      Input.set(first.db, :source, :all, %{answer: 42})

      assert Runtime.execute(first.db, unquote(query), :all, fn db, key ->
               Queries.ordinary(db, key)
             end) == %{answer: 42}

      assert {:written, _} = Session.commit(first, %{})
      Session.close(first)

      compacting = Session.open(opts)
      assert apply(Queries, unquote(query), [compacting.db, :all]) == %{answer: 42}

      assert Memo.dependencies(compacting.db, {unquote(query), :all}) ==
               {:ok, [{:input, :source, :all}]}

      assert {:written, _} = Session.commit(compacting, %{})
      Session.close(compacting)

      unchanged = Session.open(opts)
      locator = Memo.held_locator(unchanged.db, {unquote(query), :all})
      writes = Database.writes(unchanged.db)
      assert apply(Queries, unquote(query), [unchanged.db, :all]) == %{answer: 42}
      assert Database.writes(unchanged.db) == writes
      assert Memo.held_locator(unchanged.db, {unquote(query), :all}) == locator
      assert {:unchanged, _} = Session.commit(unchanged, %{})
      Session.close(unchanged)
    end
  end

  test "revalidation still shares one deadline worker and keeps clean hits", %{db: db} do
    Input.set(db, :observer, :all, self())
    Input.set(db, :source, :all, :stable)
    assert Queries.bounded(db, :all) == :stable
    Input.set(db, :source, :all, {:blocked, :stable})
    first = Task.async(fn -> Queries.bounded(db, :all) end)
    assert_receive {:started, worker}
    second = Task.async(fn -> Queries.bounded(db, :all) end)
    send(worker, :finish)
    assert Task.await(first) == :stable
    assert Task.await(second) == :stable
    refute_receive {:started, _}
    assert Queries.bounded(db, :all) == :stable
  end

  test "revalidation executes inside the deadline and records fallback reads", %{db: db} do
    Input.set(db, :observer, :all, self())
    Input.set(db, :source, :all, :stable)
    assert Queries.bounded(db, :all) == :stable
    Input.set(db, :source, :all, {:blocked, :stable})
    assert Queries.bounded(db, :all) == {:error, :timeout}
    assert_receive {:started, _worker}
    assert Memo.dependencies(db, {:bounded, :all}) == {:ok, [{:input, :source, :all}]}
  end

  test "a mutation overlapping policy execution cannot certify the result", %{db: db} do
    Database.register_query(db, :root, %{revalidate: :execute})
    Input.set(db, :source, :all, 1)
    read = fn db, _ -> Runtime.input(db, :source, :all) end
    assert Runtime.execute(db, :root, :all, read) == 1
    Input.set(db, :source, :all, 2)
    parent = self()

    task =
      Task.async(fn ->
        Runtime.execute(db, :root, :all, fn db, _ ->
          value = read.(db, :all)
          send(parent, :read)
          receive do: (:finish -> value)
        end)
      end)

    assert_receive :read
    Input.set(db, :source, :all, 3)
    send(task.pid, :finish)
    assert Task.await(task) == 2
    assert Dependencies.status(db, {:root, :all}) == :stale
    assert Runtime.execute(db, :root, :all, read) == 3
    assert Dependencies.status(db, {:root, :all}) == :clean
  end

  defp stop(db) do
    Database.shutdown(db)
  catch
    :exit, _ -> :ok
  end
end
