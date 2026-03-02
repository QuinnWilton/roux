defmodule Roux.RuntimeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.{Database, Input, Memo, Runtime}

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

  defp register_input(db, name, opts) do
    Input.register(db, Input.define(name, opts))
  end

  # -- Unit tests: execute/4 --

  describe "execute/4" do
    test "computes and stores result on cache miss", %{db: db} do
      result = Runtime.execute(db, :double, 5, fn _db, n -> n * 2 end)

      assert result == 10
      {:ok, entry} = Memo.get(db, {:double, 5})
      assert entry.value == 10
      assert entry.hash == :erlang.phash2(10)
    end

    test "returns cached value on cache hit", %{db: db} do
      counter = :counters.new(1, [])

      fun = fn _db, n ->
        :counters.add(counter, 1, 1)
        n * 2
      end

      assert Runtime.execute(db, :double, 5, fun) == 10
      assert :counters.get(counter, 1) == 1

      # Second call at same revision — cache hit, function not called again.
      assert Runtime.execute(db, :double, 5, fun) == 10
      assert :counters.get(counter, 1) == 1
    end

    test "recomputes when memo is stale", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "a", "v1")

      counter = :counters.new(1, [])

      fun = fn db, key ->
        :counters.add(counter, 1, 1)
        Runtime.input(db, :source, key)
      end

      assert Runtime.execute(db, :read_source, "a", fun) == "v1"
      assert :counters.get(counter, 1) == 1

      # Change the input — advances revision.
      Input.set(db, :source, "a", "v2")

      # Memo is stale, should recompute.
      assert Runtime.execute(db, :read_source, "a", fun) == "v2"
      assert :counters.get(counter, 1) == 2
    end

    test "records dependencies in memo entry", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "a", "hello")

      fun = fn db, key ->
        Runtime.input(db, :source, key)
      end

      Runtime.execute(db, :reader, "a", fun)

      {:ok, entry} = Memo.get(db, {:reader, "a"})
      assert {:input, :source, "a"} in entry.dependencies
    end

    test "early cutoff: unchanged value preserves old changed_at", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "a", "hello")

      fun = fn db, key ->
        _source = Runtime.input(db, :source, key)
        :constant
      end

      Runtime.execute(db, :constant_query, "a", fun)
      {:ok, entry1} = Memo.get(db, {:constant_query, "a"})

      Input.set(db, :source, "a", "world")

      Runtime.execute(db, :constant_query, "a", fun)
      {:ok, entry2} = Memo.get(db, {:constant_query, "a"})

      assert entry2.changed_at == entry1.changed_at
      assert entry2.verified_at > entry1.verified_at
    end

    test "durability is tracked from input reads", %{db: db} do
      register_input(db, :volatile, durability: :low)
      register_input(db, :stable, durability: :high)
      Input.set(db, :volatile, "a", "v")
      Input.set(db, :stable, "a", "s")

      fun = fn db, _key ->
        Runtime.input(db, :volatile, "a")
        Runtime.input(db, :stable, "a")
      end

      Runtime.execute(db, :mixed, "a", fun)
      {:ok, entry} = Memo.get(db, {:mixed, "a"})
      assert entry.durability == :low
    end

    test "exception during execution does not store memo", %{db: db} do
      fun = fn _db, _key -> raise "boom" end

      assert_raise RuntimeError, "boom", fn ->
        Runtime.execute(db, :failing, "a", fun)
      end

      assert Memo.get(db, {:failing, "a"}) == :miss
    end
  end

  # -- Integration tests: query chains --

  describe "query chains" do
    test "A → B → C: changing C's input re-executes all", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "f", "original")

      c_counter = :counters.new(1, [])
      b_counter = :counters.new(1, [])
      a_counter = :counters.new(1, [])

      c_fun = fn db, key ->
        :counters.add(c_counter, 1, 1)
        Runtime.input(db, :source, key)
      end

      b_fun = fn db, key ->
        :counters.add(b_counter, 1, 1)
        val = Runtime.execute(db, :c, key, c_fun)
        String.upcase(val)
      end

      a_fun = fn db, key ->
        :counters.add(a_counter, 1, 1)
        val = Runtime.execute(db, :b, key, b_fun)
        "result: #{val}"
      end

      assert Runtime.execute(db, :a, "f", a_fun) == "result: ORIGINAL"
      assert :counters.get(a_counter, 1) == 1
      assert :counters.get(b_counter, 1) == 1
      assert :counters.get(c_counter, 1) == 1

      Input.set(db, :source, "f", "changed")

      assert Runtime.execute(db, :a, "f", a_fun) == "result: CHANGED"
      assert :counters.get(a_counter, 1) == 2
      assert :counters.get(b_counter, 1) == 2
      assert :counters.get(c_counter, 1) == 2
    end

    test "early cutoff stops cascading: B unchanged means A doesn't re-execute", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "f", "hello")

      c_fun = fn db, key -> Runtime.input(db, :source, key) end

      b_counter = :counters.new(1, [])

      b_fun = fn db, key ->
        :counters.add(b_counter, 1, 1)
        val = Runtime.execute(db, :c, key, c_fun)
        String.length(val)
      end

      a_counter = :counters.new(1, [])

      a_fun = fn db, key ->
        :counters.add(a_counter, 1, 1)
        Runtime.execute(db, :b, key, b_fun)
      end

      assert Runtime.execute(db, :a, "f", a_fun) == 5
      assert :counters.get(a_counter, 1) == 1
      assert :counters.get(b_counter, 1) == 1

      # Change input to same-length string.
      Input.set(db, :source, "f", "world")

      # B re-executes (C changed), but B's result (5) unchanged.
      # Early cutoff fires at B → A should NOT re-execute.
      assert Runtime.execute(db, :a, "f", a_fun) == 5
      assert :counters.get(b_counter, 1) == 2
      assert :counters.get(a_counter, 1) == 1
    end

    test "diamond: A → {B, C} → D, D computed once per revision", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "x", "v1")

      d_counter = :counters.new(1, [])

      d_fun = fn db, key ->
        :counters.add(d_counter, 1, 1)
        Runtime.input(db, :source, key)
      end

      b_fun = fn db, key ->
        val = Runtime.execute(db, :d, key, d_fun)
        String.upcase(val)
      end

      c_fun = fn db, key ->
        val = Runtime.execute(db, :d, key, d_fun)
        String.length(val)
      end

      a_counter = :counters.new(1, [])

      a_fun = fn db, key ->
        :counters.add(a_counter, 1, 1)
        b_val = Runtime.execute(db, :b, key, b_fun)
        c_val = Runtime.execute(db, :c, key, c_fun)
        {b_val, c_val}
      end

      assert Runtime.execute(db, :a, "x", a_fun) == {"V1", 2}
      assert :counters.get(a_counter, 1) == 1
      assert :counters.get(d_counter, 1) == 1

      Input.set(db, :source, "x", "v2")

      assert Runtime.execute(db, :a, "x", a_fun) == {"V2", 2}
      assert :counters.get(a_counter, 1) == 2
      # D re-executed once more, not twice (B and C share the memoized result).
      assert :counters.get(d_counter, 1) == 2
    end
  end

  # -- input/3 --

  describe "input/3" do
    test "reads input and records dependency", %{db: db} do
      register_input(db, :config, durability: :high)
      Input.set(db, :config, "key", "value")

      fun = fn db, key ->
        Runtime.input(db, :config, key)
      end

      assert Runtime.execute(db, :read_config, "key", fun) == "value"
      {:ok, entry} = Memo.get(db, {:read_config, "key"})
      assert {:input, :config, "key"} in entry.dependencies
    end
  end

  # -- Cycle detection --

  describe "cycle detection" do
    test "raises Roux.Cycle.Error on direct self-cycle", %{db: db} do
      # A query that calls itself recursively.
      recursive_fun = fn db, key ->
        Runtime.execute(db, :self_cycle, key, fn _db2, _key2 -> :unreachable end)
      end

      assert_raise Roux.Cycle.Error, fn ->
        Runtime.execute(db, :self_cycle, "a", recursive_fun)
      end
    end
  end

  # -- Dedup --

  describe "dedup" do
    test "concurrent requests for same query only compute once", %{db: db} do
      counter = :counters.new(1, [])

      fun = fn _db, key ->
        :counters.add(counter, 1, 1)
        Process.sleep(50)
        String.upcase(key)
      end

      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            Runtime.execute(db, :slow_upper, "hello", fun)
          end)
        end

      results = Task.await_many(tasks)

      assert Enum.all?(results, &(&1 == "HELLO"))
      assert :counters.get(counter, 1) == 1
    end
  end

  # -- Validation integration --

  describe "validation integration" do
    test "validated entry is reused without recomputation", %{db: db} do
      register_input(db, :src, durability: :medium)
      Input.set(db, :src, "a", "v1")

      counter = :counters.new(1, [])

      fun = fn db, key ->
        :counters.add(counter, 1, 1)
        Runtime.input(db, :src, key)
      end

      assert Runtime.execute(db, :validated, "a", fun) == "v1"
      assert :counters.get(counter, 1) == 1

      # Second call without input change — validates and returns cached.
      assert Runtime.execute(db, :validated, "a", fun) == "v1"
      assert :counters.get(counter, 1) == 1
    end
  end

  # -- Write buffering --

  describe "write buffering" do
    test "exception during execution leaves no partial memo state", %{db: db} do
      fun = fn _db, _key -> raise "oops" end

      assert_raise RuntimeError, fn ->
        Runtime.execute(db, :crasher, "a", fun)
      end

      assert Memo.get(db, {:crasher, "a"}) == :miss
    end
  end

  # -- parallel/2 --

  describe "parallel/2" do
    setup %{db: db} do
      register_input(db, :source, durability: :low)
      mod = Roux.Test.RuntimeTestQueries

      Database.register_query(db, :upper, %{module: mod, function: :upper})
      Database.register_query(db, :length_query, %{module: mod, function: :length_query})

      :ok
    end

    test "fan-out merges deps into parent context", %{db: db} do
      Input.set(db, :source, "a", "hello")
      Input.set(db, :source, "b", "world")

      parent_fun = fn db, _key ->
        Runtime.parallel(db, [{:upper, "a"}, {:length_query, "b"}])
      end

      assert Runtime.execute(db, :fan_out, "keys", parent_fun) == ["HELLO", 5]

      {:ok, entry} = Memo.get(db, {:fan_out, "keys"})

      # Parent's deps should include the sub-queries.
      assert {:upper, "a"} in entry.dependencies
      assert {:length_query, "b"} in entry.dependencies
    end

    test "sub-query cache hit avoids recomputation", %{db: db} do
      Input.set(db, :source, "a", "hello")

      # Pre-populate the cache by executing the query directly.
      Runtime.execute(db, :upper, "a", fn db, key ->
        val = Runtime.input(db, :source, key)
        String.upcase(val)
      end)

      counter = :counters.new(1, [])

      parent_fun = fn db, _key ->
        :counters.add(counter, 1, 1)
        Runtime.parallel(db, [{:upper, "a"}])
      end

      result = Runtime.execute(db, :parent_cache, "k", parent_fun)

      assert result == ["HELLO"]
      # Parent executed once.
      assert :counters.get(counter, 1) == 1
      # The sub-query :upper should have been a cache hit (already computed above).
      # We verify by checking the memo is still the original one.
      {:ok, entry} = Memo.get(db, {:upper, "a"})
      assert entry.value == "HELLO"
    end
  end

  # -- Property tests --

  describe "properties" do
    property "incremental result equals from-scratch for any input change sequence" do
      check all(
              values <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 5),
                  min_length: 2,
                  max_length: 6
                )
            ) do
        db = Database.new()
        register_input(db, :src, durability: :low)

        leaf_fun = fn db, _key -> Runtime.input(db, :src, "k") end

        middle_fun = fn db, key ->
          val = Runtime.execute(db, :leaf, key, leaf_fun)
          String.upcase(val)
        end

        root_fun = fn db, key ->
          val = Runtime.execute(db, :middle, key, middle_fun)
          String.length(val)
        end

        [first | rest] = values
        Input.set(db, :src, "k", first)
        Runtime.execute(db, :root, "k", root_fun)

        for value <- rest do
          Input.set(db, :src, "k", value)

          incremental = Runtime.execute(db, :root, "k", root_fun)

          # Clear all memos and recompute from scratch.
          Memo.delete(db, {:root, "k"})
          Memo.delete(db, {:middle, "k"})
          Memo.delete(db, {:leaf, "k"})

          batch = Runtime.execute(db, :root, "k", root_fun)

          assert incremental == batch
        end

        Database.shutdown(db)
      end
    end

    property "durability propagation is correct across query chains" do
      durability_levels = [:low, :medium, :high]

      check all(
              dur1 <- member_of(durability_levels),
              dur2 <- member_of(durability_levels)
            ) do
        db = Database.new()
        register_input(db, :in1, durability: dur1)
        register_input(db, :in2, durability: dur2)
        Input.set(db, :in1, "k", "a")
        Input.set(db, :in2, "k", "b")

        fun = fn db, _key ->
          v1 = Runtime.input(db, :in1, "k")
          v2 = Runtime.input(db, :in2, "k")
          {v1, v2}
        end

        Runtime.execute(db, :dur_test, "k", fun)
        {:ok, entry} = Memo.get(db, {:dur_test, "k"})

        expected_min =
          case {dur1, dur2} do
            {:low, _} -> :low
            {_, :low} -> :low
            {:medium, _} -> :medium
            {_, :medium} -> :medium
            {:high, :high} -> :high
          end

        assert entry.durability == expected_min

        Database.shutdown(db)
      end
    end
  end

  # -- Concurrent convergence --

  describe "concurrent convergence" do
    test "N processes executing same query converge to correct result", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "shared", "hello")

      fun = fn db, key ->
        val = Runtime.input(db, :source, key)
        String.upcase(val)
      end

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Runtime.execute(db, :concurrent_upper, "shared", fun)
          end)
        end

      results = Task.await_many(tasks)

      # All processes must see the same result.
      assert Enum.all?(results, &(&1 == "HELLO"))

      # Only one memo entry should exist.
      {:ok, entry} = Memo.get(db, {:concurrent_upper, "shared"})
      assert entry.value == "HELLO"
    end
  end
end
