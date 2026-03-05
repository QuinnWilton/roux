defmodule Roux.DatabaseTest do
  use ExUnit.Case, async: true

  alias Roux.Database
  alias Roux.Intern

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

  describe "new/1" do
    test "creates all ETS tables", %{db: db} do
      assert :ets.info(db.memo_table) != :undefined
      assert :ets.info(db.query_registry) != :undefined
      assert :ets.info(db.input_registry) != :undefined
      assert :ets.info(db.task_registry) != :undefined
      assert :ets.info(db.dedup_table) != :undefined
      assert :ets.info(db.intern_registry) != :undefined
      assert :ets.info(db.entity_registry) != :undefined
    end

    test "memo table has read_concurrency", %{db: db} do
      assert :ets.info(db.memo_table, :read_concurrency) == true
    end

    test "task_registry has write_concurrency", %{db: db} do
      assert :ets.info(db.task_registry, :write_concurrency) != false
    end

    test "dedup_table has write_concurrency", %{db: db} do
      assert :ets.info(db.dedup_table, :write_concurrency) != false
    end

    test "all tables are public", %{db: db} do
      tables = [
        db.memo_table,
        db.query_registry,
        db.input_registry,
        db.task_registry,
        db.dedup_table,
        db.intern_registry,
        db.entity_registry
      ]

      for tid <- tables do
        assert :ets.info(tid, :protection) == :public
      end
    end

    test "revision starts at 0", %{db: db} do
      rev = Database.revision(db)
      assert Roux.Revision.current(rev) == 0
    end

    test "supervisor is alive", %{db: db} do
      assert Process.alive?(db.supervisor)
    end
  end

  describe "shutdown/1" do
    test "stops the supervisor" do
      db = Database.new()
      assert :ok = Database.shutdown(db)
      refute Process.alive?(db.supervisor)
    end

    test "destroys all ETS tables" do
      db = Database.new()
      Database.shutdown(db)

      assert :ets.info(db.memo_table) == :undefined
      assert :ets.info(db.query_registry) == :undefined
      assert :ets.info(db.input_registry) == :undefined
      assert :ets.info(db.task_registry) == :undefined
      assert :ets.info(db.dedup_table) == :undefined
      assert :ets.info(db.intern_registry) == :undefined
      assert :ets.info(db.entity_registry) == :undefined
    end
  end

  describe "register_query/3" do
    test "stores the query definition in the registry", %{db: db} do
      definition = %{function: :my_query, arity: 2}
      assert :ok = Database.register_query(db, :my_query, definition)
      assert [{:my_query, ^definition}] = :ets.lookup(db.query_registry, :my_query)
    end

    test "raises on duplicate registration", %{db: db} do
      Database.register_query(db, :q, %{v: 1})

      assert_raise ArgumentError, ~r/already registered/, fn ->
        Database.register_query(db, :q, %{v: 2})
      end

      # Original definition is preserved.
      assert [{:q, %{v: 1}}] = :ets.lookup(db.query_registry, :q)
    end
  end

  describe "register_input/3" do
    test "stores the input with options as a map", %{db: db} do
      assert :ok = Database.register_input(db, :source_text, durability: :low)
      assert [{:source_text, %{durability: :low}}] = :ets.lookup(db.input_registry, :source_text)
    end

    test "defaults to empty opts", %{db: db} do
      assert :ok = Database.register_input(db, :config)
      assert [{:config, %{}}] = :ets.lookup(db.input_registry, :config)
    end
  end

  describe "register_entity/2" do
    test "creates an ETS table for the entity", %{db: db} do
      assert :ok = Database.register_entity(db, MyEntity)
      [{MyEntity, tid}] = :ets.lookup(db.entity_registry, MyEntity)
      assert :ets.info(tid) != :undefined
      assert :ets.info(tid, :protection) == :public
    end

    test "is idempotent", %{db: db} do
      assert :ok = Database.register_entity(db, IdempotentEntity)
      [{IdempotentEntity, tid1}] = :ets.lookup(db.entity_registry, IdempotentEntity)

      assert :ok = Database.register_entity(db, IdempotentEntity)
      [{IdempotentEntity, tid2}] = :ets.lookup(db.entity_registry, IdempotentEntity)

      assert tid1 == tid2
    end
  end

  describe "intern_table/2" do
    test "creates an intern table on first access", %{db: db} do
      table = Database.intern_table(db, :strings)
      assert %Intern{} = table
    end

    test "returns the same table on second access", %{db: db} do
      t1 = Database.intern_table(db, :types)
      t2 = Database.intern_table(db, :types)
      assert t1.forward == t2.forward
      assert t1.reverse == t2.reverse
    end

    test "different names yield different tables", %{db: db} do
      t1 = Database.intern_table(db, :names)
      t2 = Database.intern_table(db, :paths)
      assert t1.forward != t2.forward
    end

    test "interned table is functional", %{db: db} do
      table = Database.intern_table(db, :values)
      id = Intern.intern(table, "hello")
      assert Intern.resolve(table, id) == {:ok, "hello"}
    end
  end

  describe "revision/1" do
    test "returns the revision tracker", %{db: db} do
      rev = Database.revision(db)
      assert %Roux.Revision{} = rev
    end

    test "revision is shared (same atomics ref)", %{db: db} do
      rev1 = Database.revision(db)
      rev2 = Database.revision(db)
      assert rev1.counter == rev2.counter
    end
  end

  describe "independence" do
    test "two databases have independent tables" do
      db1 = Database.new()
      db2 = Database.new()

      on_exit(fn ->
        try do
          Database.shutdown(db1)
        catch
          :exit, _ -> :ok
        end

        try do
          Database.shutdown(db2)
        catch
          :exit, _ -> :ok
        end
      end)

      :ets.insert(db1.memo_table, {:key, :val1})
      :ets.insert(db2.memo_table, {:key, :val2})

      assert [{:key, :val1}] = :ets.lookup(db1.memo_table, :key)
      assert [{:key, :val2}] = :ets.lookup(db2.memo_table, :key)
    end

    test "two databases have independent revisions" do
      db1 = Database.new()
      db2 = Database.new()

      on_exit(fn ->
        try do
          Database.shutdown(db1)
        catch
          :exit, _ -> :ok
        end

        try do
          Database.shutdown(db2)
        catch
          :exit, _ -> :ok
        end
      end)

      Roux.Revision.advance(Database.revision(db1), :low)

      assert Roux.Revision.current(Database.revision(db1)) == 1
      assert Roux.Revision.current(Database.revision(db2)) == 0
    end
  end

  describe "crash recovery" do
    test "data survives TableOwner crash", %{db: db} do
      # Write data to memo table.
      :ets.insert(db.memo_table, {:query_a, :result_a})

      # Kill the TableOwner.
      table_owner_pid = find_table_owner(db.supervisor)
      Process.exit(table_owner_pid, :kill)

      # Wait for supervisor to restart it.
      wait_for_table_owner_restart(db.supervisor, table_owner_pid)

      # Data survives — the tid is stable across transfers.
      assert [{:query_a, :result_a}] = :ets.lookup(db.memo_table, :query_a)
    end

    test "struct refs remain valid after TableOwner crash", %{db: db} do
      table_owner_pid = find_table_owner(db.supervisor)
      Process.exit(table_owner_pid, :kill)
      wait_for_table_owner_restart(db.supervisor, table_owner_pid)

      # All table refs still work.
      assert :ets.info(db.memo_table) != :undefined
      assert :ets.info(db.query_registry) != :undefined
      assert :ets.info(db.input_registry) != :undefined
      assert :ets.info(db.task_registry) != :undefined
      assert :ets.info(db.dedup_table) != :undefined
      assert :ets.info(db.intern_registry) != :undefined
      assert :ets.info(db.entity_registry) != :undefined
    end

    test "Heir crash causes cold restart — old tids are stale", %{db: db} do
      old_memo = db.memo_table
      :ets.insert(old_memo, {:key, :value})

      # Kill the Heir — rest_for_one takes down TableOwner too.
      heir_pid = find_heir(db.supervisor)
      Process.exit(heir_pid, :kill)

      # Wait for both to restart.
      wait_for_heir_restart(db.supervisor, heir_pid)

      # Old tids are now stale (tables destroyed when both died).
      assert :ets.info(old_memo) == :undefined
    end
  end

  # -- Helpers --

  defp find_table_owner(sup_pid) do
    sup_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Roux.Database.TableOwner, pid, :worker, _} -> pid
      _ -> nil
    end)
  end

  defp find_heir(sup_pid) do
    sup_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Roux.Database.Heir, pid, :worker, _} -> pid
      _ -> nil
    end)
  end

  defp wait_for_table_owner_restart(sup_pid, old_pid) do
    wait_until(fn ->
      new_pid = find_table_owner(sup_pid)
      new_pid != nil and new_pid != old_pid and Process.alive?(new_pid)
    end)
  end

  defp wait_for_heir_restart(sup_pid, old_pid) do
    wait_until(fn ->
      new_pid = find_heir(sup_pid)
      new_pid != nil and new_pid != old_pid and Process.alive?(new_pid)
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
