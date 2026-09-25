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

  # -- encode_snapshot/1 and restore/2 (encoded) --

  describe "encode_snapshot/1 and restore/2" do
    # An encoded snapshot restores without loading anything: the rows stay
    # encoded until an operation misses, then load, and the operation
    # looks again.

    defp restored_from(values) do
      source = Intern.new(:enc_src)
      ids = Map.new(values, &{&1, Intern.intern(source, &1)})
      snapshot = Intern.encode_snapshot(source)
      Intern.destroy(source)

      table = Intern.new(:enc_dst)
      :ok = Intern.restore(table, snapshot)
      {table, ids, snapshot}
    end

    test "leaves the rows encoded until the table is used" do
      {table, ids, _snapshot} = restored_from(~w(alpha beta))

      assert :ets.info(table.forward, :size) == 0
      assert Intern.resolve(table, ids["beta"]) == {:ok, "beta"}
      assert :ets.info(table.forward, :size) == 2

      assert :ets.select(table.reverse, [{{:"$1", :"$2"}, [{:>, :"$1", 0}], [{{:"$1", :"$2"}}]}])
             |> Enum.sort() == [{1, "alpha"}, {2, "beta"}]

      Intern.destroy(table)
    end

    test "every operation that misses loads the rows and looks again" do
      for operation <- [
            fn t, ids -> assert Intern.intern(t, "alpha") == ids["alpha"] end,
            fn t, ids -> assert Intern.lookup(t, "alpha") == {:ok, ids["alpha"]} end,
            fn t, ids -> assert Intern.resolve(t, ids["alpha"]) == {:ok, "alpha"} end,
            fn t, _ids -> assert Intern.size(t) == 2 end,
            fn t, ids -> assert {"alpha", ids["alpha"]} in Intern.snapshot(t).forward end
          ] do
        {table, ids, _snapshot} = restored_from(~w(alpha beta))
        operation.(table, ids)
        assert Intern.lookup(table, "beta") == {:ok, ids["beta"]}
        Intern.destroy(table)
      end
    end

    test "a new value takes an ID past every restored one" do
      {table, ids, _snapshot} = restored_from(~w(alpha beta))

      new_id = Intern.intern(table, "gamma")

      assert new_id > Enum.max(Map.values(ids))
      assert Intern.resolve(table, new_id) == {:ok, "gamma"}
      assert Intern.lookup(table, "alpha") == {:ok, ids["alpha"]}
      assert Intern.resolve(table, new_id + 1) == :error

      Intern.destroy(table)
    end

    test "an unknown ID or value is still unknown after the load" do
      {table, _ids, _snapshot} = restored_from(~w(alpha))

      assert Intern.resolve(table, 99) == :error
      assert Intern.lookup(table, "zeta") == :error
      assert Intern.size(table) == 1

      Intern.destroy(table)
    end

    test "an unused restored table hands back the encoding it came from" do
      # Compressed, which `encode_snapshot/1` never produces itself: a
      # table that encoded its rows again would hand back other bytes.
      forward = :erlang.term_to_binary([{"alpha", 1}], compressed: 9)
      table = Intern.new(:enc_reuse)
      :ok = Intern.restore(table, %{version: 3, forward: forward, counter: 1})

      assert Intern.encode_snapshot(table) == %{version: 3, forward: forward, counter: 1}

      # Read, it holds the same rows: the same encoding.
      assert Intern.resolve(table, 1) == {:ok, "alpha"}
      assert Intern.intern(table, "alpha") == 1
      assert Intern.encode_snapshot(table) == %{version: 3, forward: forward, counter: 1}

      # Interned into, it encodes what it holds now.
      id = Intern.intern(table, "beta")
      snapshot = Intern.encode_snapshot(table)
      assert snapshot.counter == id

      assert Enum.sort(:erlang.binary_to_term(snapshot.forward)) ==
               [{"alpha", 1}, {"beta", id}]

      # The restored encoding is let go once it cannot be reused.
      assert :ets.lookup(table.reverse, 0) == []

      Intern.destroy(table)
    end

    test "refuses an encoded snapshot whose rows are not a binary" do
      table = Intern.new(:enc_bad)

      assert_raise ArgumentError, ~r/unsupported Roux.Intern snapshot/, fn ->
        Intern.restore(table, %{version: 3, forward: [{"a", 1}], counter: 1})
      end

      assert Intern.size(table) == 0
      Intern.destroy(table)
    end

    property "restores what snapshot/1 would, and interns on from the same counter" do
      check all(
              values <- uniq_list_of(term(), max_length: 30),
              later <- list_of(term(), max_length: 10)
            ) do
        source = Intern.new(:prop_enc_src)
        Enum.each(values, &Intern.intern(source, &1))

        eager = Intern.new(:prop_enc_eager)
        :ok = Intern.restore(eager, Intern.snapshot(source))
        lazy = Intern.new(:prop_enc_lazy)
        :ok = Intern.restore(lazy, Intern.encode_snapshot(source))

        # The same answers, in an order that makes the lazy table load
        # on whichever operation comes first.
        for value <- Enum.reverse(values) ++ later do
          assert Intern.lookup(lazy, value) == Intern.lookup(eager, value)
          assert Intern.intern(lazy, value) == Intern.intern(eager, value)
        end

        for {_value, id} <- :ets.tab2list(eager.forward) do
          assert Intern.resolve(lazy, id) == Intern.resolve(eager, id)
        end

        assert Intern.size(lazy) == Intern.size(eager)

        assert Intern.snapshot(lazy) |> Map.update!(:forward, &Enum.sort/1) ==
                 Intern.snapshot(eager) |> Map.update!(:forward, &Enum.sort/1)

        Enum.each([source, eager, lazy], &Intern.destroy/1)
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
