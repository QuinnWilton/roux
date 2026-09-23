defmodule Roux.InternTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.Intern

  setup do
    %{table: Intern.new(:test)}
  end

  describe "intern/2" do
    test "returns a positive integer ID", %{table: table} do
      id = Intern.intern(table, "value")
      assert is_integer(id) and id > 0
    end

    test "is idempotent — same value returns same ID", %{table: table} do
      id1 = Intern.intern(table, "foo")
      id2 = Intern.intern(table, "foo")
      assert id1 == id2
    end

    test "distinct values get distinct IDs", %{table: table} do
      id1 = Intern.intern(table, "foo")
      id2 = Intern.intern(table, "bar")
      assert id1 != id2
    end
  end

  describe "resolve/2" do
    test "round-trip returns the original value", %{table: table} do
      id = Intern.intern(table, "hello")
      assert Intern.resolve(table, id) == {:ok, "hello"}
    end

    test "works with various term types", %{table: table} do
      values = [
        :an_atom,
        42,
        3.14,
        "a string",
        {1, 2, 3},
        [1, 2, 3],
        %{a: 1},
        {:nested, [%{deep: true}]}
      ]

      for value <- values do
        id = Intern.intern(table, value)
        assert Intern.resolve(table, id) == {:ok, value}
      end
    end

    test "returns :error for unknown ID", %{table: table} do
      assert Intern.resolve(table, 999) == :error
    end
  end

  describe "resolve!/2" do
    test "returns the value directly", %{table: table} do
      id = Intern.intern(table, "test")
      assert Intern.resolve!(table, id) == "test"
    end

    test "raises UnknownIdError for unknown ID", %{table: table} do
      assert_raise Intern.UnknownIdError, "unknown intern ID: 999", fn ->
        Intern.resolve!(table, 999)
      end
    end
  end

  describe "lookup/2" do
    test "returns {:ok, id} for interned values", %{table: table} do
      id = Intern.intern(table, "present")
      assert Intern.lookup(table, "present") == {:ok, id}
    end

    test "returns :error for unknown values", %{table: table} do
      assert Intern.lookup(table, "absent") == :error
    end

    test "does not intern the value", %{table: table} do
      assert Intern.lookup(table, "ghost") == :error
      assert Intern.size(table) == 0
    end
  end

  describe "size/1" do
    test "returns 0 for empty table", %{table: table} do
      assert Intern.size(table) == 0
    end

    test "tracks interned values", %{table: table} do
      Intern.intern(table, "a")
      Intern.intern(table, "b")
      Intern.intern(table, "c")
      assert Intern.size(table) == 3
    end

    test "does not double-count re-interned values", %{table: table} do
      Intern.intern(table, "x")
      Intern.intern(table, "x")
      assert Intern.size(table) == 1
    end
  end

  describe "destroy/1" do
    test "returns :ok" do
      table = Intern.new(:destroy_test)
      assert Intern.destroy(table) == :ok
    end

    test "deletes both ETS tables" do
      table = Intern.new(:destroy_test)
      Intern.destroy(table)

      assert :ets.info(table.forward) == :undefined
      assert :ets.info(table.reverse) == :undefined
    end
  end

  describe "concurrent interning" do
    test "same value from multiple processes yields same ID", %{table: table} do
      tasks =
        for _ <- 1..20 do
          Task.async(fn -> Intern.intern(table, "shared") end)
        end

      ids = Task.await_many(tasks)
      assert Enum.uniq(ids) |> length() == 1
    end

    test "different values from multiple processes yield distinct IDs", %{table: table} do
      tasks =
        for i <- 1..20 do
          Task.async(fn -> Intern.intern(table, "value_#{i}") end)
        end

      ids = Task.await_many(tasks)
      assert length(Enum.uniq(ids)) == 20
    end

    test "no orphaned reverse entries after concurrent race", %{table: table} do
      tasks =
        for _ <- 1..20 do
          Task.async(fn -> Intern.intern(table, "raced") end)
        end

      Task.await_many(tasks)

      # Forward and reverse tables should have the same size: exactly 1 entry.
      assert :ets.info(table.forward, :size) == 1
      assert :ets.info(table.reverse, :size) == 1
    end
  end

  # -- snapshot/1 and restore/2 --

  describe "snapshot/1 and restore/2" do
    test "stores each value once, tagged with the format version" do
      table = Intern.new(:snap_once)
      Enum.each(~w(alpha beta gamma), &Intern.intern(table, &1))

      snapshot = Intern.snapshot(table)

      assert %{version: 2, counter: 3} = snapshot
      refute Map.has_key?(snapshot, :reverse)
      assert snapshot.forward |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ~w(alpha beta gamma)

      Intern.destroy(table)
    end

    test "rebuilds the reverse table on restore" do
      table = Intern.new(:snap_src)
      id = Intern.intern(table, "hello")
      snapshot = Intern.snapshot(table)
      Intern.destroy(table)

      restored = Intern.new(:snap_dst)
      assert :ok = Intern.restore(restored, snapshot)

      assert Intern.resolve(restored, id) == {:ok, "hello"}
      assert Intern.lookup(restored, "hello") == {:ok, id}
      assert Intern.intern(restored, "world") == id + 1

      Intern.destroy(restored)
    end

    test "does not persist an orphaned reverse row from a lost insert race" do
      table = Intern.new(:snap_orphan)
      id = Intern.intern(table, "winner")
      # The state a losing `intern/2` leaves between its reverse insert and
      # its cleanup: a reverse row no forward row points at.
      :ets.insert(table.reverse, {id + 1, "winner"})
      :atomics.put(table.counter, 1, id + 1)

      restored = Intern.new(:snap_orphan_dst)
      Intern.restore(restored, Intern.snapshot(table))

      assert Intern.lookup(restored, "winner") == {:ok, id}
      assert Intern.resolve(restored, id + 1) == :error

      Intern.destroy(table)
      Intern.destroy(restored)
    end

    test "refuses the unversioned two-table format" do
      table = Intern.new(:snap_legacy)

      legacy = %{forward: [{"a", 1}], reverse: [{1, "a"}], counter: 1}

      assert_raise ArgumentError, ~r/unsupported Roux.Intern snapshot/, fn ->
        Intern.restore(table, legacy)
      end

      assert Intern.size(table) == 0
      Intern.destroy(table)
    end

    property "restore(snapshot(t)) reproduces both tables and the counter" do
      check all(values <- list_of(term(), max_length: 50)) do
        table = Intern.new(:prop_snap_src)
        Enum.each(values, &Intern.intern(table, &1))

        restored = Intern.new(:prop_snap_dst)
        Intern.restore(restored, Intern.snapshot(table))

        assert Enum.sort(:ets.tab2list(restored.forward)) ==
                 Enum.sort(:ets.tab2list(table.forward))

        assert Enum.sort(:ets.tab2list(restored.reverse)) ==
                 Enum.sort(:ets.tab2list(table.reverse))

        assert :atomics.get(restored.counter, 1) == :atomics.get(table.counter, 1)

        Intern.destroy(table)
        Intern.destroy(restored)
      end
    end
  end

  # -- Property tests --

  describe "properties" do
    property "round-trip: intern then resolve returns original value" do
      check all(values <- list_of(term(), min_length: 1, max_length: 50)) do
        table = Intern.new(:prop_roundtrip)

        for value <- values do
          id = Intern.intern(table, value)
          assert Intern.resolve(table, id) == {:ok, value}
        end

        Intern.destroy(table)
      end
    end

    property "distinct values get distinct IDs" do
      check all(values <- uniq_list_of(term(), min_length: 2, max_length: 50)) do
        table = Intern.new(:prop_distinct)
        ids = Enum.map(values, &Intern.intern(table, &1))

        assert length(Enum.uniq(ids)) == length(values)

        Intern.destroy(table)
      end
    end

    property "concurrent intern of same value yields same ID" do
      check all(
              value <- term(),
              n <- integer(2..10)
            ) do
        table = Intern.new(:prop_concurrent)

        tasks = for _ <- 1..n, do: Task.async(fn -> Intern.intern(table, value) end)
        ids = Task.await_many(tasks)

        assert length(Enum.uniq(ids)) == 1

        Intern.destroy(table)
      end
    end

    property "lookup agrees with intern" do
      check all(values <- list_of(term(), min_length: 1, max_length: 50)) do
        table = Intern.new(:prop_lookup)

        for value <- values do
          id = Intern.intern(table, value)
          assert Intern.lookup(table, value) == {:ok, id}
        end

        Intern.destroy(table)
      end
    end

    property "size equals number of unique interned values" do
      check all(values <- list_of(term(), min_length: 0, max_length: 50)) do
        table = Intern.new(:prop_size)
        Enum.each(values, &Intern.intern(table, &1))

        assert Intern.size(table) == length(Enum.uniq(values))

        Intern.destroy(table)
      end
    end
  end
end
