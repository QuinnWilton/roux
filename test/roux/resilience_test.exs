defmodule Roux.ResilienceTest do
  use ExUnit.Case, async: true

  alias Roux.{Database, Entity, Intern}

  @sample Roux.Test.SampleEntity

  setup do
    db = Database.new()

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    %{db: db}
  end

  # ============================================================================
  # Dynamic table ownership (give_away fix)
  # ============================================================================

  describe "entity table ownership survives process exit" do
    test "entity table created in a Task remains accessible after the Task exits", %{db: db} do
      task =
        Task.async(fn ->
          Database.register_entity(db, @sample)
          Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)
        end)

      entity_id = Task.await(task)

      # The creating process (Task) is now dead. Table must still work.
      assert Entity.field(db, @sample, entity_id, :name) == :foo
      assert Entity.field(db, @sample, entity_id, :body) == :bar
    end

    test "entity table created in a spawned process survives that process dying", %{db: db} do
      parent = self()

      pid =
        spawn(fn ->
          Database.register_entity(db, @sample)
          id = Entity.create(db, @sample, %{name: :a, body: :b, return_type: :c}, 1)
          send(parent, {:id, id})
        end)

      ref = Process.monitor(pid)
      receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)

      entity_id = receive do: ({:id, id} -> id)

      # Process is dead, but the entity table lives on.
      assert Entity.field(db, @sample, entity_id, :name) == :a
    end

    test "entity table is owned by TableOwner, not the creating process", %{db: db} do
      task =
        Task.async(fn ->
          Database.register_entity(db, @sample)
        end)

      Task.await(task)

      [{@sample, tid}] = :ets.lookup(db.entity_registry, @sample)
      owner = :ets.info(tid, :owner)

      # Owner must be the TableOwner process, not the dead Task.
      assert owner == db.table_owner
      assert Process.alive?(owner)
    end
  end

  describe "intern table ownership survives process exit" do
    test "intern table created in a Task remains functional after Task exits", %{db: db} do
      task =
        Task.async(fn ->
          table = Database.intern_table(db, :test_strings)
          id = Intern.intern(table, "hello")
          {table, id}
        end)

      {table, id} = Task.await(task)

      # Task is dead. Intern table must still resolve.
      assert Intern.resolve(table, id) == {:ok, "hello"}

      # Can still intern new values.
      id2 = Intern.intern(table, "world")
      assert Intern.resolve(table, id2) == {:ok, "world"}
    end

    test "intern table forward/reverse tables owned by TableOwner", %{db: db} do
      task =
        Task.async(fn ->
          Database.intern_table(db, :ownership_test)
        end)

      table = Task.await(task)

      assert :ets.info(table.forward, :owner) == db.table_owner
      assert :ets.info(table.reverse, :owner) == db.table_owner
    end
  end

  # ============================================================================
  # Concurrent entity/intern registration
  # ============================================================================

  describe "concurrent register_entity" do
    test "multiple processes registering the same entity type get a single table", %{db: db} do
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Database.register_entity(db, @sample)
            [{@sample, tid}] = :ets.lookup(db.entity_registry, @sample)
            tid
          end)
        end

      tids = Task.await_many(tasks)

      # All processes must see the same table ID.
      assert length(Enum.uniq(tids)) == 1
    end

    test "concurrent entity creation after concurrent registration works", %{db: db} do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Database.register_entity(db, @sample)
            name = :"entity_#{i}"

            Entity.create(
              db,
              @sample,
              %{name: name, body: :val, return_type: :int},
              1
            )
          end)
        end

      ids = Task.await_many(tasks)

      # All 10 entities should have unique IDs.
      assert length(Enum.uniq(ids)) == 10

      # All should be readable.
      for {id, i} <- Enum.zip(ids, 1..10) do
        assert Entity.field(db, @sample, id, :name) == :"entity_#{i}"
      end
    end
  end

  describe "concurrent intern_table creation" do
    test "multiple processes creating the same intern table get a single table", %{db: db} do
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            table = Database.intern_table(db, :concurrent_test)
            {table.forward, table.reverse}
          end)
        end

      results = Task.await_many(tasks)

      forwards = Enum.map(results, &elem(&1, 0)) |> Enum.uniq()
      reverses = Enum.map(results, &elem(&1, 1)) |> Enum.uniq()

      assert length(forwards) == 1
      assert length(reverses) == 1
    end
  end

  # ============================================================================
  # Database shutdown under load
  # ============================================================================

  describe "shutdown resilience" do
    test "shutdown during entity operations does not raise in the caller" do
      db = Database.new()
      Database.register_entity(db, @sample)

      # Create some entities first.
      for i <- 1..5 do
        Entity.create(db, @sample, %{name: :"pre_#{i}", body: :v, return_type: :t}, 1)
      end

      # Shutdown is clean.
      assert :ok = Database.shutdown(db)

      # All tables are gone.
      assert :ets.info(db.memo_table) == :undefined
      assert :ets.info(db.entity_registry) == :undefined
    end

    test "shutdown cleans up dynamically created entity tables" do
      db = Database.new()
      Database.register_entity(db, @sample)
      [{@sample, entity_tid}] = :ets.lookup(db.entity_registry, @sample)

      # Entity table exists.
      assert :ets.info(entity_tid) != :undefined

      Database.shutdown(db)

      # Entity table is destroyed along with everything else.
      assert :ets.info(entity_tid) == :undefined
    end

    test "shutdown cleans up dynamically created intern tables" do
      db = Database.new()
      table = Database.intern_table(db, :shutdown_test)

      assert :ets.info(table.forward) != :undefined
      assert :ets.info(table.reverse) != :undefined

      Database.shutdown(db)

      assert :ets.info(table.forward) == :undefined
      assert :ets.info(table.reverse) == :undefined
    end
  end

  # ============================================================================
  # TableOwner crash recovery with dynamic tables
  # ============================================================================

  describe "TableOwner crash recovery with dynamic tables" do
    test "core tables survive TableOwner crash", %{db: db} do
      :ets.insert(db.memo_table, {:test_key, :test_value})

      kill_table_owner(db)

      assert :ets.info(db.memo_table) != :undefined
      assert :ets.info(db.entity_registry) != :undefined
      assert [{:test_key, :test_value}] = :ets.lookup(db.memo_table, :test_key)
    end

    test "dynamically created entity tables survive TableOwner crash", %{db: db} do
      Database.register_entity(db, @sample)
      id = Entity.create(db, @sample, %{name: :survivor, body: :data, return_type: :int}, 1)
      [{@sample, entity_tid}] = :ets.lookup(db.entity_registry, @sample)

      kill_table_owner(db)

      # Dynamic table survived via heir protection set on give_away.
      assert :ets.info(entity_tid) != :undefined
      assert Entity.field(db, @sample, id, :name) == :survivor
    end

    test "dynamically created intern tables survive TableOwner crash", %{db: db} do
      table = Database.intern_table(db, :crash_survivor)
      id = Intern.intern(table, "persist")

      kill_table_owner(db)

      assert Intern.resolve(table, id) == {:ok, "persist"}
    end

    test "all tables survive a second TableOwner crash", %{db: db} do
      Database.register_entity(db, @sample)
      id = Entity.create(db, @sample, %{name: :double, body: :crash, return_type: :test}, 1)
      :ets.insert(db.memo_table, {:memo_key, :memo_val})

      # First crash.
      kill_table_owner(db)

      # Second crash.
      kill_table_owner(db)

      # Everything survived both crashes.
      assert :ets.info(db.memo_table) != :undefined
      assert [{:memo_key, :memo_val}] = :ets.lookup(db.memo_table, :memo_key)
      assert Entity.field(db, @sample, id, :name) == :double
    end
  end

  # ============================================================================
  # Entity operations under adversarial conditions
  # ============================================================================

  describe "entity field tracking under concurrent updates" do
    test "concurrent updates to same entity preserve field-level change tracking", %{db: db} do
      Database.register_entity(db, @sample)

      # Initial creation.
      Entity.create(db, @sample, %{name: :shared, body: :v1, return_type: :t1}, 1)

      # Concurrent updates from multiple processes.
      tasks =
        for rev <- 2..10 do
          Task.async(fn ->
            Entity.create(
              db,
              @sample,
              %{name: :shared, body: :"v#{rev}", return_type: :t1},
              rev
            )
          end)
        end

      Task.await_many(tasks)

      # return_type was never changed — changed_at must be 1.
      id = elem(Entity.lookup(db, @sample, {:shared}), 1)
      assert Entity.field_changed_at(db, @sample, id, :return_type) == 1

      # body was changed — changed_at must be > 1.
      assert Entity.field_changed_at(db, @sample, id, :body) > 1
    end
  end

  describe "entity refcount under concurrent increment/decrement" do
    test "concurrent increments produce correct final count", %{db: db} do
      Database.register_entity(db, @sample)
      id = Entity.create(db, @sample, %{name: :reftest, body: :b, return_type: :t}, 1)

      n = 50

      tasks =
        for _ <- 1..n do
          Task.async(fn ->
            Entity.increment_refcount(db, @sample, id)
          end)
        end

      Task.await_many(tasks)

      assert Entity.refcount(db, @sample, id) == n
    end

    test "balanced increments and decrements cancel out", %{db: db} do
      Database.register_entity(db, @sample)
      id = Entity.create(db, @sample, %{name: :balanced, body: :b, return_type: :t}, 1)

      n = 30

      # First: increment n times.
      inc_tasks =
        for _ <- 1..n do
          Task.async(fn -> Entity.increment_refcount(db, @sample, id) end)
        end

      Task.await_many(inc_tasks)
      assert Entity.refcount(db, @sample, id) == n

      # Then: decrement n times concurrently.
      dec_tasks =
        for _ <- 1..n do
          Task.async(fn -> Entity.decrement_refcount(db, @sample, id) end)
        end

      Task.await_many(dec_tasks)
      assert Entity.refcount(db, @sample, id) == 0
    end
  end

  # -- Helpers --

  defp kill_table_owner(db) do
    old_owner = find_table_owner(db.supervisor)
    Process.exit(old_owner, :kill)

    wait_until(fn ->
      new = find_table_owner(db.supervisor)
      new != nil and new != old_owner and Process.alive?(new)
    end)
  end

  defp find_table_owner(sup_pid) do
    sup_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Roux.Database.TableOwner, pid, :worker, _} -> pid
      _ -> nil
    end)
  end

  defp wait_until(fun, attempts \\ 100) do
    if fun.() do
      :ok
    else
      if attempts <= 0, do: raise("wait_until timed out")
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end
end
