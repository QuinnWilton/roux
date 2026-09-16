defmodule Roux.RuntimeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.{Database, Entity, Input, Memo, Runtime}

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

  # -- Served values --

  describe "served values" do
    test "a hit hands back the memoized value without reading it out of ETS again", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "a", [["row", "1"]])
      fun = fn db, key -> Runtime.input(db, :source, key) end

      first = Runtime.execute(db, :rows, "a", fun)
      second = Runtime.execute(db, :rows, "a", fun)

      assert first == second
      # The same heap term, not a fresh ETS copy: the cache serves it.
      assert {:ok, %Memo.Entry{value: ^first}} = Memo.get(db, {:rows, "a"})
      assert :erts_debug.same(first, second)
    end

    test "a changed value replaces the served one; an unchanged one keeps it", %{db: db} do
      register_input(db, :source, durability: :low)
      register_input(db, :other, durability: :low)
      Input.set(db, :source, "a", "v1")
      Input.set(db, :other, "a", 0)

      fun = fn db, key ->
        _ = Runtime.input(db, :other, key)
        Runtime.input(db, :source, key)
      end

      assert Runtime.execute(db, :read_source, "a", fun) == "v1"

      # A revision that leaves the value alone: early cutoff, same value served.
      Input.set(db, :other, "a", 1)
      assert Runtime.execute(db, :read_source, "a", fun) == "v1"

      Input.set(db, :source, "a", "v2")
      assert Runtime.execute(db, :read_source, "a", fun) == "v2"
      assert Runtime.execute(db, :read_source, "a", fun) == "v2"
    end

    test "two databases in one process never serve each other's values", %{db: db} do
      other = Database.new()

      on_exit(fn ->
        try do
          Database.shutdown(other)
        catch
          :exit, _ -> :ok
        end
      end)

      for d <- [db, other] do
        register_input(d, :source, durability: :low)
      end

      Input.set(db, :source, "a", :from_db)
      Input.set(other, :source, "a", :from_other)
      fun = fn d, key -> Runtime.input(d, :source, key) end

      assert Runtime.execute(db, :read_source, "a", fun) == :from_db
      assert Runtime.execute(other, :read_source, "a", fun) == :from_other
      assert Runtime.execute(db, :read_source, "a", fun) == :from_db
      assert Runtime.execute(other, :read_source, "a", fun) == :from_other
    end

    test "drop_cached_values/1 forgets this process's copies for one database", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "a", "v1")
      fun = fn db, key -> Runtime.input(db, :source, key) end
      assert Runtime.execute(db, :read_source, "a", fun) == "v1"

      assert Enum.any?(Process.get(), fn {k, _} -> match?({{Runtime, :value}, _, _}, k) end)
      assert :ok = Runtime.drop_cached_values(db)
      refute Enum.any?(Process.get(), fn {k, _} -> match?({{Runtime, :value}, _, _}, k) end)

      # Served again from ETS, and equal.
      assert Runtime.execute(db, :read_source, "a", fun) == "v1"
    end
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

  # -- Untracked --

  describe "untracked/1" do
    test "discards deps recorded inside the block, keeps deps outside it", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "dep", "v1")
      Input.set(db, :source, "real", "r1")

      fun = fn db, _key ->
        warm = Runtime.untracked(fn -> Runtime.input(db, :source, "dep") end)
        real = Runtime.input(db, :source, "real")
        {warm, real}
      end

      assert Runtime.execute(db, :untracked_outer, "a", fun) == {"v1", "r1"}

      {:ok, entry} = Memo.get(db, {:untracked_outer, "a"})
      assert {:input, :source, "real"} in entry.dependencies
      refute {:input, :source, "dep"} in entry.dependencies
    end

    test "changing an untracked-only input does not invalidate the query", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "dep", "v1")

      counter = :counters.new(1, [])

      fun = fn db, _key ->
        :counters.add(counter, 1, 1)
        Runtime.untracked(fn -> Runtime.input(db, :source, "dep") end)
      end

      assert Runtime.execute(db, :untracked_only, "a", fun) == "v1"
      assert :counters.get(counter, 1) == 1

      Input.set(db, :source, "dep", "v2")

      # By design: the untracked read is not a dependency, so the memo
      # stays valid and the stale value is served without recomputing.
      assert Runtime.execute(db, :untracked_only, "a", fun) == "v1"
      assert :counters.get(counter, 1) == 1
    end

    test "does not lower the enclosing query's durability", %{db: db} do
      register_input(db, :volatile, durability: :low)
      Input.set(db, :volatile, "a", "v")

      fun = fn db, _key ->
        Runtime.untracked(fn -> Runtime.input(db, :volatile, "a") end)
        :constant
      end

      Runtime.execute(db, :untracked_durability, "a", fun)

      {:ok, entry} = Memo.get(db, {:untracked_durability, "a"})
      assert entry.durability == :high
    end

    test "nested queries inside the block still memoize with their own deps", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "k", "v1")

      inner = fn db, key -> Runtime.input(db, :source, key) end

      fun = fn db, _key ->
        Runtime.untracked(fn -> Runtime.execute(db, :untracked_inner, "k", inner) end)
      end

      assert Runtime.execute(db, :untracked_caller, "a", fun) == "v1"

      # The inner query's own memo entry is intact, with its input dep.
      {:ok, inner_entry} = Memo.get(db, {:untracked_inner, "k"})
      assert {:input, :source, "k"} in inner_entry.dependencies

      # The caller recorded no dep on the inner query.
      {:ok, outer_entry} = Memo.get(db, {:untracked_caller, "a"})
      refute {:untracked_inner, "k"} in outer_entry.dependencies
    end

    test "preserves cycle detection through untracked calls", %{db: db} do
      recursive_fun = fn db, key ->
        Runtime.untracked(fn ->
          Runtime.execute(db, :untracked_cycle, key, fn _db2, _key2 -> :unreachable end)
        end)
      end

      assert_raise Roux.Cycle.Error, fn ->
        Runtime.execute(db, :untracked_cycle, "a", recursive_fun)
      end
    end

    test "restores dep tracking after an exception inside the block", %{db: db} do
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "dep", "v1")
      Input.set(db, :source, "real", "r1")

      fun = fn db, _key ->
        try do
          Runtime.untracked(fn ->
            Runtime.input(db, :source, "dep")
            raise "boom"
          end)
        rescue
          _ -> :ok
        end

        Runtime.input(db, :source, "real")
      end

      assert Runtime.execute(db, :untracked_raise, "a", fun) == "r1"

      {:ok, entry} = Memo.get(db, {:untracked_raise, "a"})
      assert {:input, :source, "real"} in entry.dependencies
      refute {:input, :source, "dep"} in entry.dependencies
    end

    test "runs the fun plainly when no query context is active", %{db: _db} do
      assert Runtime.untracked(fn -> :plain end) == :plain
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

    test "a waiter is released when the claimant FINISHES, not when it dies", %{db: db} do
      # The test above passes with or without a correct wakeup, because
      # Task.async processes exit as soon as they are done and the waiter's
      # monitor fires. That is the only reason waiting on `:DOWN` ever
      # looked like it worked.
      #
      # Here the claimant stays alive afterwards — a GenServer, an LSP
      # loop, an IEx session, or planchette's Session.Server, all of which
      # run queries and then keep running. Waiting for it to die is waiting
      # forever.
      parent = self()
      counter = :counters.new(1, [])

      fun = fn _db, key ->
        :counters.add(counter, 1, 1)
        send(parent, :computing)
        Process.sleep(100)
        String.upcase(key)
      end

      claimant =
        spawn(fn ->
          send(parent, {:claimed, Runtime.execute(db, :slow_upper, "hello", fun)})
          Process.sleep(:infinity)
        end)

      # Only start waiting once the claimant is demonstrably inside the
      # query, so this really exercises the contended path.
      assert_receive :computing, 1_000

      waiter = Task.async(fn -> Runtime.execute(db, :slow_upper, "hello", fun) end)

      assert Task.await(waiter, 2_000) == "HELLO",
             "the waiter never woke: it was waiting for the claimant to exit"

      assert_receive {:claimed, "HELLO"}, 1_000
      assert :counters.get(counter, 1) == 1, "the waiter recomputed instead of reusing the memo"

      assert Process.alive?(claimant), "the claimant exited; this test proves nothing"
      Process.exit(claimant, :kill)
    end

    test "several waiters on one key are all released", %{db: db} do
      parent = self()

      fun = fn _db, key ->
        send(parent, :computing)
        Process.sleep(100)
        String.upcase(key)
      end

      claimant =
        spawn(fn ->
          Runtime.execute(db, :slow_upper, "hello", fun)
          Process.sleep(:infinity)
        end)

      assert_receive :computing, 1_000

      waiters =
        for _ <- 1..5, do: Task.async(fn -> Runtime.execute(db, :slow_upper, "hello", fun) end)

      assert Task.await_many(waiters, 2_000) == List.duplicate("HELLO", 5)

      Process.exit(claimant, :kill)
    end

    test "a waiter still wakes when the claimant dies mid-computation", %{db: db} do
      # The monitor path has to survive: an abnormal exit leaves no
      # completion message, and a waiter that only listened for one would
      # hang exactly as badly as before, just in a rarer case.
      parent = self()

      fun = fn _db, key ->
        send(parent, :computing)
        Process.sleep(:infinity)
        key
      end

      claimant = spawn(fn -> Runtime.execute(db, :doomed, "k", fun) end)
      assert_receive :computing, 1_000

      waiter =
        Task.async(fn ->
          Runtime.execute(db, :doomed, "k", fn _db, key -> String.upcase(key) end)
        end)

      Process.exit(claimant, :kill)

      assert Task.await(waiter, 2_000) == "K"
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

  # -- Entity helpers --

  @sample Roux.Test.SampleEntity

  describe "create/3" do
    test "creates entity and records in output_entities", %{db: db} do
      Database.register_entity(db, @sample)

      fun = fn db, _key ->
        id = Runtime.create(db, @sample, %{name: :foo, body: :bar, return_type: :int})
        {:created, id}
      end

      {:created, entity_id} = Runtime.execute(db, :creator, "a", fun)

      # Entity exists in ETS.
      assert Entity.field(db, @sample, entity_id, :name) == :foo
      assert Entity.field(db, @sample, entity_id, :body) == :bar

      # Recorded in memo's output_entities.
      {:ok, entry} = Memo.get(db, {:creator, "a"})
      assert {@sample, entity_id} in entry.output_entities
    end
  end

  describe "field/4" do
    test "reads field and records entity field dependency", %{db: db} do
      Database.register_entity(db, @sample)
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "a", "v1")

      # Producer query: creates an entity from input.
      producer = fn db, key ->
        val = Runtime.input(db, :source, key)
        Runtime.create(db, @sample, %{name: :item, body: val, return_type: :int})
      end

      # Consumer query: reads a field from the entity.
      consumer = fn db, key ->
        entity_id = Runtime.execute(db, :producer, key, producer)
        Runtime.field(db, @sample, entity_id, :body)
      end

      assert Runtime.execute(db, :consumer, "a", consumer) == "v1"

      {:ok, entry} = Memo.get(db, {:consumer, "a"})
      # Should have a field-level dependency.
      assert Enum.any?(entry.dependencies, fn
               {:entity_field, @sample, _id, :body} -> true
               _ -> false
             end)
    end

    test "field-level early cutoff: unchanged field does not invalidate consumer", %{db: db} do
      Database.register_entity(db, @sample)
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "a", "v1")

      producer = fn db, key ->
        val = Runtime.input(db, :source, key)
        Runtime.create(db, @sample, %{name: :item, body: val, return_type: :int})
      end

      consumer_counter = :counters.new(1, [])

      # Consumer reads :return_type, NOT :body.
      consumer = fn db, key ->
        :counters.add(consumer_counter, 1, 1)
        entity_id = Runtime.execute(db, :producer, key, producer)
        Runtime.field(db, @sample, entity_id, :return_type)
      end

      assert Runtime.execute(db, :consumer, "a", consumer) == :int
      assert :counters.get(consumer_counter, 1) == 1

      # Change input → body changes, but return_type stays :int.
      Input.set(db, :source, "a", "v2")

      assert Runtime.execute(db, :consumer, "a", consumer) == :int
      # Consumer should NOT re-execute because :return_type didn't change.
      assert :counters.get(consumer_counter, 1) == 1
    end

    test "field change invalidates consumer", %{db: db} do
      Database.register_entity(db, @sample)
      register_input(db, :source, durability: :low)
      Input.set(db, :source, "a", "v1")

      producer = fn db, key ->
        val = Runtime.input(db, :source, key)
        Runtime.create(db, @sample, %{name: :item, body: val, return_type: :int})
      end

      consumer_counter = :counters.new(1, [])

      # Consumer reads :body, which DOES change.
      consumer = fn db, key ->
        :counters.add(consumer_counter, 1, 1)
        entity_id = Runtime.execute(db, :producer, key, producer)
        Runtime.field(db, @sample, entity_id, :body)
      end

      assert Runtime.execute(db, :consumer, "a", consumer) == "v1"
      assert :counters.get(consumer_counter, 1) == 1

      Input.set(db, :source, "a", "v2")

      assert Runtime.execute(db, :consumer, "a", consumer) == "v2"
      # Consumer MUST re-execute because :body changed.
      assert :counters.get(consumer_counter, 1) == 2
    end
  end

  describe "read/3" do
    test "returns all fields as a map and records deps on each", %{db: db} do
      Database.register_entity(db, @sample)

      producer = fn db, _key ->
        Runtime.create(db, @sample, %{name: :foo, body: :bar, return_type: :int})
      end

      consumer = fn db, key ->
        entity_id = Runtime.execute(db, :producer, key, producer)
        Runtime.read(db, @sample, entity_id)
      end

      result = Runtime.execute(db, :consumer, "a", consumer)

      assert result == %{name: :foo, body: :bar, return_type: :int}

      # Should have deps on all fields.
      {:ok, entry} = Memo.get(db, {:consumer, "a"})

      for field <- [:name, :body, :return_type] do
        assert Enum.any?(entry.dependencies, fn
                 {:entity_field, @sample, _id, ^field} -> true
                 _ -> false
               end)
      end
    end
  end

  describe "lookup/3" do
    test "finds entity by identity key", %{db: db} do
      Database.register_entity(db, @sample)

      fun = fn db, _key ->
        Runtime.create(db, @sample, %{name: :foo, body: :bar, return_type: :int})
        :ok
      end

      Runtime.execute(db, :creator, "a", fun)

      # Lookup outside a query context.
      assert {:ok, _id} = Entity.lookup(db, @sample, {:foo})
      assert :error == Entity.lookup(db, @sample, {:nonexistent})
    end
  end

  describe "query!/3" do
    test "returns result when query succeeds", %{db: db} do
      Database.register_query(db, :ok_q, %{module: __MODULE__, function: :__ok_query__})

      result =
        Runtime.execute(db, :outer, "a", fn db, _key ->
          Runtime.query!(db, :ok_q, "a")
        end)

      assert result == {:ok, 42}
    end

    test "throws on error and is caught by try/catch", %{db: db} do
      Database.register_query(db, :err_q, %{module: __MODULE__, function: :__err_query__})

      result =
        Runtime.execute(db, :outer, "a", fn db, _key ->
          try do
            Runtime.query!(db, :err_q, "a")
          catch
            :throw, {:roux_query_error, reason} -> {:error, reason}
          end
        end)

      assert result == {:error, :boom}
    end
  end

  # Test query functions for query!/3 tests.
  @doc false
  def __ok_query__(db, key), do: Runtime.execute(db, :ok_q, key, fn _, _ -> {:ok, 42} end)
  @doc false
  def __err_query__(db, key), do: Runtime.execute(db, :err_q, key, fn _, _ -> {:error, :boom} end)

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
