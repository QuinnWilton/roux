defmodule Roux.DemandTimeoutTest do
  use ExUnit.Case, async: true

  alias Roux.{Blob, Database, Input, Lang, Memo, Revision, Runtime}

  @moduletag :tmp_dir

  defmodule Queries do
    use Roux.Query

    definput :work
    definput :observer

    defquery :bounded,
      key: key,
      timeout: 1_000,
      on_timeout: &__MODULE__.fallback/2,
      transient: &match?({:error, :timeout}, &1) do
      Runtime.query(db, :work, key)
    end

    defquery :parent, key: key do
      {:parent, Runtime.query(db, :bounded, key)}
    end

    defquery :scoped,
      key: key,
      timeout: 1_000,
      on_timeout: &__MODULE__.fallback/2,
      around_demand: {__MODULE__, :scope} do
      Runtime.query(db, :work, key)
      send(Runtime.input(db, :observer, :all), :scoped_body)
      :stable
    end

    def scope(_db, _name, _key, run) do
      Process.put(:demand_scope_test, :inside)

      try do
        run.()
      after
        Process.delete(:demand_scope_test)
      end
    end

    defquery :bounded_blob,
      key: key,
      timeout: 1_000,
      store: :blob,
      on_timeout: &__MODULE__.fallback/2 do
      Runtime.query(db, :work, key)
    end

    defquery :work, key: key do
      observer = Runtime.input(db, :observer, :all)

      case Runtime.input(db, :work, key) do
        {:value, value} ->
          value

        {:scoped, _changed_input} ->
          send(observer, {:scope_seen, Process.get(:demand_scope_test)})
          :unchanged_child_result

        :hang ->
          send(observer, {:started, key, self()})

          receive do
            :continue -> :finished
          end

        {:sequence, members} ->
          Enum.map(members, &Runtime.query(db, :work, &1))

        {:parallel, members} ->
          Runtime.parallel(db, Enum.map(members, &{:work, &1}))

        {:nested, member} ->
          Runtime.query(db, :bounded, member)

        {:sleep, ms} ->
          Process.sleep(ms)
      end
    end

    def fallback(db, key) do
      Runtime.input(db, :work, key)
      send(Runtime.input(db, :observer, :all), {:fallback, key})
      {:error, :timeout}
    end
  end

  setup %{tmp_dir: dir} do
    db = Database.new(blob: Blob.open!(Path.join(dir, "store")))
    Lang.register_module(db, Queries)
    Input.set(db, :observer, :all, self())

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    %{db: db}
  end

  test "timeout covers changed dependencies during warm validation", %{db: db} do
    Input.set(db, :work, :file, {:value, :original})
    assert Queries.parent(db, :file) == {:parent, :original}
    Input.set(db, :work, :file, :hang)
    assert Queries.parent(db, :file) == {:parent, {:error, :timeout}}
    assert_received {:started, :file, worker}
    refute Process.alive?(worker)
    assert {:ok, %{persist: :transient}} = Memo.get(db, {:bounded, :file})
    assert_clean(db)
  end

  test "the demand scope covers child recomputation even when early cutoff skips the body", %{
    db: db
  } do
    Input.set(db, :work, :file, {:scoped, :before})
    assert Queries.scoped(db, :file) == :stable
    assert_received {:scope_seen, :inside}
    assert_received :scoped_body

    Input.set(db, :work, :file, {:scoped, :after})
    assert Queries.scoped(db, :file) == :stable
    assert_received {:scope_seen, :inside}
    refute_received :scoped_body

    assert Queries.scoped(db, :file) == :stable
    refute_received {:scope_seen, _}
    assert_clean(db)
  end

  test "concurrent callers share one timeout result", %{db: db} do
    Input.set(db, :work, :file, :hang)
    one = Task.async(fn -> Queries.bounded(db, :file) end)
    assert_receive {:started, :file, _worker}, 1_000
    two = Task.async(fn -> Queries.bounded(db, :file) end)
    assert Task.await(one) == {:error, :timeout}
    assert Task.await(two) == {:error, :timeout}
    assert_received {:fallback, :file}
    refute_received {:fallback, :file}
    refute_received {:started, :file, _}
    assert_clean(db)
  end

  test "one deadline covers the sum of sequential child work", %{db: db} do
    Input.set(db, :work, :file, {:sequence, [:first, :second]})
    Input.set(db, :work, :first, {:sleep, 600})
    Input.set(db, :work, :second, {:sleep, 600})
    assert Queries.bounded(db, :file) == {:error, :timeout}
    assert {:ok, _} = Memo.get(db, {:work, :first})
    assert :miss = Memo.get(db, {:work, :second})
    assert_clean(db)
  end

  test "timeout cancels nested fan-out and clears owned registrations", %{db: db} do
    Input.set(db, :work, :file, {:parallel, [:first, :middle]})
    Input.set(db, :work, :middle, {:parallel, [:second, :third]})
    for key <- [:first, :second, :third], do: Input.set(db, :work, key, :hang)
    assert Queries.bounded(db, :file) == {:error, :timeout}

    for key <- [:first, :second, :third] do
      assert_received {:started, ^key, pid}
      refute Process.alive?(pid)
    end

    assert_clean(db)
  end

  test "caller cancellation stops nested boundaries and their descendants", %{db: db} do
    Input.set(db, :work, :file, {:nested, :inner})
    Input.set(db, :work, :inner, {:parallel, [:first, :second]})
    for key <- [:first, :second], do: Input.set(db, :work, key, :hang)
    caller = spawn(fn -> Queries.bounded(db, :file) end)
    assert_receive {:started, :first, one}, 1_000
    assert_receive {:started, :second, two}, 1_000
    refs = for pid <- [one, two], do: Process.monitor(pid)
    Process.exit(caller, :kill)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _})
    # Worker death precedes the coordinator's ownership cleanup.
    assert_clean_eventually(db, 100)
  end

  test "unchanged child output retains early cutoff", %{db: db} do
    Input.set(db, :work, :file, {:value, :same})
    assert Queries.parent(db, :file) == {:parent, :same}
    {:ok, before} = Memo.get(db, {:parent, :file})
    Input.set(db, :work, :unrelated, {:value, :new})
    assert Queries.parent(db, :file) == {:parent, :same}
    {:ok, after_validation} = Memo.get(db, {:parent, :file})
    assert after_validation.changed_at == before.changed_at
    assert_clean(db)
  end

  test "a result committed just before timeout wins over the fallback", %{db: db} do
    Input.set(db, :work, :file, {:value, :success})
    handler = make_ref()

    :telemetry.attach(
      handler,
      [:roux, :query, :stop],
      &__MODULE__.pause_after_commit/4,
      {Database.id(db), self()}
    )

    try do
      first = Task.async(fn -> Queries.bounded(db, :file) end)
      assert_receive :committed, 1_000
      assert Queries.bounded(db, :file) == :success
      assert Task.await(first) == :success
      refute_received {:fallback, :file}
      assert_clean(db)
    after
      :telemetry.detach(handler)
    end
  end

  test "missing-blob recovery cannot replace a settled result at the same revision", %{db: db} do
    Input.set(db, :work, :file, :hang)
    revision = Revision.current(db.revision)
    key = {:bounded_blob, :file}
    missing = Blob.digest("missing value")

    Memo.restore_persisted(db, [
      {key, :erlang.phash2(:success), revision, revision, [], :medium, [], {:blob, missing}, nil,
       []}
    ])

    assert catch_exit(Queries.bounded_blob(db, :file)) == {:timeout, key}
    assert Memo.verification_state(db, key) == {:ok, revision, :medium}
    assert Memo.held_digest(db, key) == {:ok, missing}
    refute_received {:fallback, :file}
    assert_clean(db)
  end

  @doc false
  def pause_after_commit(_, _, %{database: db, query_name: :bounded}, {db, observer}) do
    send(observer, :committed)
    Process.sleep(:infinity)
  end

  def pause_after_commit(_, _, _, _), do: :ok

  defp assert_clean(db) do
    for table <- [db.dedup_table, db.task_registry, db.dedup_waiters],
        do: assert(:ets.tab2list(table) == [])
  end

  defp assert_clean_eventually(db, remaining) do
    if remaining > 0 and
         Enum.any?(
           [db.dedup_table, db.task_registry, db.dedup_waiters],
           &(:ets.info(&1, :size) != 0)
         ) do
      Process.sleep(5)
      assert_clean_eventually(db, remaining - 1)
    else
      assert_clean(db)
    end
  end
end
