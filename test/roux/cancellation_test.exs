defmodule Roux.CancellationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.{Cancellation, Database, Input, Memo, Runtime}
  alias Roux.Memo.Entry

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

  defp make_entry(opts) do
    %Entry{
      value: Keyword.get(opts, :value, :some_value),
      hash: Keyword.get(opts, :hash, :erlang.phash2(:some_value)),
      changed_at: Keyword.get(opts, :changed_at, 1),
      verified_at: Keyword.get(opts, :verified_at, 1),
      dependencies: Keyword.get(opts, :dependencies, []),
      durability: Keyword.get(opts, :durability, :low),
      output_entities: Keyword.get(opts, :output_entities, [])
    }
  end

  defp spawn_blocking_task(db, query_key) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:ready, self()})
        receive do: (:unblock -> :ok)
      end)

    receive do: ({:ready, ^pid} -> :ok)
    :ets.insert(db.dedup_table, {query_key, pid})
    :ets.insert(db.task_registry, {query_key, pid})
    pid
  end

  # -- register_task / unregister_task --

  describe "register_task/3" do
    test "inserts entry into task registry", %{db: db} do
      pid = self()
      assert :ok = Cancellation.register_task(db, {:q, :k}, pid)
      assert [{_, ^pid}] = :ets.lookup(db.task_registry, {:q, :k})
    end

    test "overwrites existing entry for same key", %{db: db} do
      pid1 = spawn(fn -> receive do: (:stop -> :ok) end)
      pid2 = spawn(fn -> receive do: (:stop -> :ok) end)

      Cancellation.register_task(db, {:q, :k}, pid1)
      Cancellation.register_task(db, {:q, :k}, pid2)

      assert [{_, ^pid2}] = :ets.lookup(db.task_registry, {:q, :k})
      send(pid1, :stop)
      send(pid2, :stop)
    end
  end

  describe "unregister_task/3" do
    test "removes entry from task registry", %{db: db} do
      Cancellation.register_task(db, {:q, :k}, self())
      assert :ok = Cancellation.unregister_task(db, {:q, :k})
      assert [] = :ets.lookup(db.task_registry, {:q, :k})
    end

    test "no-op when key not registered", %{db: db} do
      assert :ok = Cancellation.unregister_task(db, {:q, :nonexistent})
    end
  end

  # -- cancel_dependents --

  describe "cancel_dependents/2" do
    test "kills task that directly depends on target", %{db: db} do
      input_key = {:input, :source, :a}
      query_key = {:reader, :a}

      # Set up memo entry showing reader depends on input.
      Memo.put(db, query_key, make_entry(dependencies: [input_key]))

      pid = spawn_blocking_task(db, query_key)
      ref = Process.monitor(pid)

      Cancellation.cancel_dependents(db, input_key)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert [] = :ets.lookup(db.task_registry, query_key)
      assert [] = :ets.lookup(db.dedup_table, query_key)
    end

    test "kills task with transitive dependency", %{db: db} do
      input_key = {:input, :source, :a}
      mid_key = {:middle, :a}
      top_key = {:top, :a}

      # top -> middle -> input.
      Memo.put(db, mid_key, make_entry(dependencies: [input_key]))
      Memo.put(db, top_key, make_entry(dependencies: [mid_key]))

      pid = spawn_blocking_task(db, top_key)
      ref = Process.monitor(pid)

      Cancellation.cancel_dependents(db, input_key)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end

    test "does not kill task with no dependency on target", %{db: db} do
      input_key = {:input, :source, :a}
      unrelated_key = {:unrelated, :b}

      # Unrelated task depends on a different input.
      Memo.put(db, unrelated_key, make_entry(dependencies: [{:input, :other, :b}]))

      pid = spawn_blocking_task(db, unrelated_key)
      ref = Process.monitor(pid)

      Cancellation.cancel_dependents(db, input_key)

      # Task should still be alive.
      refute_receive {:DOWN, ^ref, :process, ^pid, :killed}, 50
      send(pid, :unblock)
    end

    test "handles diamond dependency (task killed once)", %{db: db} do
      # Diamond: top -> {left, right} -> bottom.
      bottom_key = {:input, :source, :a}
      left_key = {:left, :a}
      right_key = {:right, :a}
      top_key = {:top, :a}

      Memo.put(db, left_key, make_entry(dependencies: [bottom_key]))
      Memo.put(db, right_key, make_entry(dependencies: [bottom_key]))
      Memo.put(db, top_key, make_entry(dependencies: [left_key, right_key]))

      pid = spawn_blocking_task(db, top_key)
      ref = Process.monitor(pid)

      Cancellation.cancel_dependents(db, bottom_key)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      # Only one DOWN message — task killed once.
      refute_receive {:DOWN, _, :process, ^pid, _}, 50
    end

    test "no-op when no tasks are registered", %{db: db} do
      assert :ok = Cancellation.cancel_dependents(db, {:input, :source, :a})
    end

    test "no-op when task has no memo entry", %{db: db} do
      # Task is registered but has no memo entry (just started, no deps recorded).
      pid = spawn_blocking_task(db, {:new_query, :k})
      ref = Process.monitor(pid)

      Cancellation.cancel_dependents(db, {:input, :source, :a})

      refute_receive {:DOWN, ^ref, :process, ^pid, :killed}, 50
      send(pid, :unblock)
    end
  end

  # -- cancel_all --

  describe "cancel_all/1" do
    test "kills all registered tasks", %{db: db} do
      pid1 = spawn_blocking_task(db, {:q1, :a})
      pid2 = spawn_blocking_task(db, {:q2, :b})
      ref1 = Process.monitor(pid1)
      ref2 = Process.monitor(pid2)

      Cancellation.cancel_all(db)

      assert_receive {:DOWN, ^ref1, :process, ^pid1, :killed}
      assert_receive {:DOWN, ^ref2, :process, ^pid2, :killed}

      assert [] = :ets.lookup(db.task_registry, {:q1, :a})
      assert [] = :ets.lookup(db.task_registry, {:q2, :b})
      assert [] = :ets.lookup(db.dedup_table, {:q1, :a})
      assert [] = :ets.lookup(db.dedup_table, {:q2, :b})
    end

    test "no-op when no tasks registered", %{db: db} do
      assert :ok = Cancellation.cancel_all(db)
    end
  end

  # -- await_or_cancel --

  describe "await_or_cancel/3" do
    test "returns {:ok, value} when task completes normally", %{db: db} do
      query_key = {:q, :k}

      pid =
        spawn(fn ->
          receive do: (:ready -> :ok)
        end)

      Cancellation.register_task(db, query_key, pid)
      :ets.insert(db.dedup_table, {query_key, pid})

      # Simulate task completion: store memo, then let process exit.
      Memo.put(db, query_key, make_entry(value: 42))
      send(pid, :ready)

      assert {:ok, 42} = Cancellation.await_or_cancel(db, query_key, 1000)
    end

    test "returns :cancelled on timeout", %{db: db} do
      query_key = {:q, :k}
      pid = spawn_blocking_task(db, query_key)

      assert :cancelled = Cancellation.await_or_cancel(db, query_key, 50)

      # Task should be killed after timeout.
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    test "returns :cancelled when task crashes", %{db: db} do
      query_key = {:q, :k}

      pid =
        spawn(fn ->
          receive do: (:crash -> exit(:boom))
        end)

      Cancellation.register_task(db, query_key, pid)
      :ets.insert(db.dedup_table, {query_key, pid})

      send(pid, :crash)

      assert :cancelled = Cancellation.await_or_cancel(db, query_key, 1000)
    end

    test "returns {:ok, value} when no task but memo exists", %{db: db} do
      query_key = {:q, :k}
      Memo.put(db, query_key, make_entry(value: :cached))

      assert {:ok, :cached} = Cancellation.await_or_cancel(db, query_key, 1000)
    end

    test "returns :cancelled when no task and no memo", %{db: db} do
      assert :cancelled = Cancellation.await_or_cancel(db, {:q, :missing}, 1000)
    end

    test "handles noproc race (task exits before monitor)", %{db: db} do
      query_key = {:q, :k}

      # Create a process that exits immediately.
      pid = spawn(fn -> :ok end)
      # Wait for it to die.
      ref = Process.monitor(pid)
      receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)

      # Register the dead pid — simulates race between lookup and monitor.
      Cancellation.register_task(db, query_key, pid)

      # With memo: should return the value.
      Memo.put(db, query_key, make_entry(value: :race_value))
      assert {:ok, :race_value} = Cancellation.await_or_cancel(db, query_key, 1000)
    end
  end

  # -- cleanup invariants --

  describe "cleanup invariants" do
    test "kill_task cleans both dedup and registry", %{db: db} do
      query_key = {:q, :k}
      pid = spawn_blocking_task(db, query_key)
      ref = Process.monitor(pid)

      # Cancel via cancel_all which calls kill_task.
      Cancellation.cancel_all(db)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert [] = :ets.lookup(db.dedup_table, query_key)
      assert [] = :ets.lookup(db.task_registry, query_key)
    end

    test "telemetry events are emitted on cancel", %{db: db} do
      :telemetry.attach(
        "cancel-test",
        [:roux, :cancel, :task],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, metadata})
        end,
        nil
      )

      query_key = {:q, :k}
      pid = spawn_blocking_task(db, query_key)
      Process.monitor(pid)

      Cancellation.cancel_all(db)

      assert_receive {:DOWN, _, :process, ^pid, :killed}
      assert_receive {:telemetry, %{query_name: :q, key: :k, reason: :shutdown}}

      :telemetry.detach("cancel-test")
    end

    test "telemetry emits :input_changed for cancel_dependents", %{db: db} do
      test_pid = self()

      :telemetry.attach(
        "cancel-dep-test",
        [:roux, :cancel, :task],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, metadata})
        end,
        nil
      )

      input_key = {:input, :source, :a}
      query_key = {:reader, :a}
      Memo.put(db, query_key, make_entry(dependencies: [input_key]))

      pid = spawn_blocking_task(db, query_key)
      Process.monitor(pid)

      Cancellation.cancel_dependents(db, input_key)

      assert_receive {:DOWN, _, :process, ^pid, :killed}
      assert_receive {:telemetry, %{query_name: :reader, key: :a, reason: :input_changed}}

      :telemetry.detach("cancel-dep-test")
    end

    test "telemetry emits :timeout for await_or_cancel", %{db: db} do
      test_pid = self()

      :telemetry.attach(
        "cancel-timeout-test",
        [:roux, :cancel, :task],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, metadata})
        end,
        nil
      )

      query_key = {:q, :k}
      _pid = spawn_blocking_task(db, query_key)

      Cancellation.await_or_cancel(db, query_key, 50)

      assert_receive {:telemetry, %{query_name: :q, key: :k, reason: :timeout}}

      :telemetry.detach("cancel-timeout-test")
    end
  end

  # -- Property tests --

  describe "properties" do
    property "cancel_all leaves registry and dedup empty for any set of tasks", %{db: db} do
      check all(keys <- list_of(atom(:alphanumeric), min_length: 1, max_length: 10)) do
        query_keys = Enum.map(keys, &{:prop_query, &1})

        pids =
          Enum.map(query_keys, fn qk ->
            pid = spawn_blocking_task(db, qk)
            Process.monitor(pid)
            pid
          end)

        Cancellation.cancel_all(db)

        # Wait for all processes to die.
        Enum.each(pids, fn pid ->
          receive do
            {:DOWN, _, :process, ^pid, _} -> :ok
          after
            1000 -> flunk("Process #{inspect(pid)} did not die")
          end
        end)

        # Registry and dedup must be clean for these keys.
        Enum.each(query_keys, fn qk ->
          assert [] == :ets.lookup(db.task_registry, qk)
          assert [] == :ets.lookup(db.dedup_table, qk)
        end)

        # All pids must be dead.
        Enum.each(pids, fn pid ->
          refute Process.alive?(pid)
        end)
      end
    end

    property "concurrent input changes with queries leave no leaked tasks or partial state", %{
      db: db
    } do
      Input.register(db, Input.define(:prop_input, durability: :low))

      check all(
              input_keys <- list_of(integer(1..5), min_length: 1, max_length: 5),
              new_values <- list_of(integer(), min_length: 1, max_length: 5)
            ) do
        # Set up initial input values.
        Enum.each(input_keys, fn k ->
          Input.set(db, :prop_input, k, :initial)
        end)

        query_fun = fn db, key ->
          Runtime.input(db, :prop_input, key)
        end

        # Spawn concurrent query tasks.
        query_tasks =
          Enum.map(input_keys, fn k ->
            Task.async(fn ->
              try do
                Runtime.execute(db, :prop_reader, k, query_fun)
              catch
                :exit, :killed -> :cancelled
              end
            end)
          end)

        # Concurrently change inputs and cancel dependents.
        Enum.zip(input_keys, Stream.cycle(new_values))
        |> Enum.each(fn {k, v} ->
          Input.set(db, :prop_input, k, v)
          Cancellation.cancel_dependents(db, {:input, :prop_input, k})
        end)

        # Wait for all query tasks to finish.
        Enum.each(query_tasks, fn task ->
          Task.await(task, 5000)
        end)

        # Invariant: task registry is empty for these keys.
        Enum.each(input_keys, fn k ->
          assert [] == :ets.lookup(db.task_registry, {:prop_reader, k})
        end)

        # Invariant: dedup table has no stale entries for these keys.
        Enum.each(input_keys, fn k ->
          assert [] == :ets.lookup(db.dedup_table, {:prop_reader, k})
        end)

        # Invariant: all memo entries (if present) are well-formed.
        Enum.each(input_keys, fn k ->
          case Memo.get(db, {:prop_reader, k}) do
            {:ok, %Entry{value: v}} ->
              assert is_integer(v) or v == :initial

            :miss ->
              :ok
          end
        end)
      end
    end
  end
end
