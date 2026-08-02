# Concuerror test modules for Roux.Cancellation.
#
# Each module exercises a specific concurrent race condition with 2-3
# processes. Concuerror systematically explores all scheduler interleavings
# and verifies the assertions hold in every case.
#
# Run with:
#   MIX_ENV=test mix concuerror -m Roux.Concurrency.CancellationCompletionRaceTest
#   MIX_ENV=test mix concuerror --all

defmodule Roux.Concurrency.CancellationCompletionRaceTest do
  @moduledoc """
  Cancel racing with task completion. The task either completes and
  leaves a memo entry, or is cancelled and leaves nothing. Never a
  partial state or crash.
  """

  alias Roux.{Cancellation, Memo}
  alias Roux.Memo.Entry

  def concuerror_options do
    [treat_as_normal: [:shutdown, :killed]]
  end

  def test do
    db = make_db()
    parent = self()
    query_key = {:q, :k}

    entry = %Entry{
      value: :result,
      hash: :erlang.phash2(:result),
      changed_at: 1,
      verified_at: 1,
      dependencies: [],
      durability: :low,
      output_entities: []
    }

    # Task process: registers, computes, writes memo, unregisters.
    task_pid =
      spawn(fn ->
        Cancellation.register_task(db, query_key, self())
        :ets.insert(db.dedup_table, {query_key, self()})

        # Simulate computation.
        Memo.put(db, query_key, entry)
        :ets.delete(db.dedup_table, query_key)
        Cancellation.unregister_task(db, query_key)

        send(parent, :task_done)
      end)

    task_ref = Process.monitor(task_pid)

    # Canceller: races with task completion.
    cancel_pid =
      spawn(fn ->
        Cancellation.cancel_all(db)
        send(parent, :cancel_done)
      end)

    cancel_ref = Process.monitor(cancel_pid)

    # Wait for canceller to finish (it's never killed, always completes).
    receive do
      :cancel_done -> :ok
      {:DOWN, ^cancel_ref, :process, ^cancel_pid, _} -> :ok
    end

    # Wait for task to finish or be killed.
    receive do
      :task_done -> :ok
      {:DOWN, ^task_ref, :process, ^task_pid, _} -> :ok
    end

    # Invariant: either the memo has the result or it doesn't.
    # Never partial state.
    case Memo.get(db, query_key) do
      {:ok, entry_result} ->
        :result = entry_result.value

      :miss ->
        :ok
    end

    # Dedup table must be clean.
    [] = :ets.lookup(db.dedup_table, query_key)

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    dedup = :ets.new(:dedup, [:set, :public, write_concurrency: true])
    waiters = :ets.new(:waiters, [:duplicate_bag, :public, write_concurrency: true])
    task_reg = :ets.new(:task_reg, [:set, :public, write_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: task_reg,
      dedup_table: dedup,
      dedup_waiters: waiters,
      intern_registry: reg,
      entity_registry: reg,
      table_owner: self(),
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.dedup_table)
    :ets.delete(db.task_registry)
    :ets.delete(db.input_registry)
  end
end

defmodule Roux.Concurrency.CancellationRegistrationRaceTest do
  @moduledoc """
  cancel_dependents racing with new task registration. Either the new
  task is cancelled (if it registered before the scan), or it survives
  (if it registered after). No missed cancellations or crashes.
  """

  alias Roux.{Cancellation, Memo}
  alias Roux.Memo.Entry

  def concuerror_options do
    [treat_as_normal: [:shutdown, :killed]]
  end

  def test do
    db = make_db()
    parent = self()
    input_key = {:input, :source, :a}
    query_key = {:q, :a}

    entry = %Entry{
      value: :result,
      hash: :erlang.phash2(:result),
      changed_at: 1,
      verified_at: 1,
      dependencies: [input_key],
      durability: :low,
      output_entities: []
    }

    # Set up memo showing query depends on input.
    Memo.put(db, query_key, entry)

    # Process 1: registers a task for the query, then exits.
    task_pid =
      spawn(fn ->
        Cancellation.register_task(db, query_key, self())
        :ets.insert(db.dedup_table, {query_key, self()})

        # Simulate computation completing.
        Cancellation.unregister_task(db, query_key)
        :ets.delete(db.dedup_table, query_key)

        send(parent, :task_done)
      end)

    task_ref = Process.monitor(task_pid)

    # Process 2: cancels dependents of the input.
    cancel_pid =
      spawn(fn ->
        Cancellation.cancel_dependents(db, input_key)
        send(parent, :cancel_done)
      end)

    cancel_ref = Process.monitor(cancel_pid)

    # Wait for canceller (never killed, always completes).
    receive do
      :cancel_done -> :ok
      {:DOWN, ^cancel_ref, :process, ^cancel_pid, _} -> :ok
    end

    # Wait for task (may be killed).
    receive do
      :task_done -> :ok
      {:DOWN, ^task_ref, :process, ^task_pid, _} -> :ok
    end

    # Invariant: task is either done (completed normally) or dead
    # (caught by cancellation). Either way, no crash.

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    dedup = :ets.new(:dedup, [:set, :public, write_concurrency: true])
    waiters = :ets.new(:waiters, [:duplicate_bag, :public, write_concurrency: true])
    task_reg = :ets.new(:task_reg, [:set, :public, write_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: task_reg,
      dedup_table: dedup,
      dedup_waiters: waiters,
      intern_registry: reg,
      entity_registry: reg,
      table_owner: self(),
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.dedup_table)
    :ets.delete(db.task_registry)
    :ets.delete(db.input_registry)
  end
end

defmodule Roux.Concurrency.CancellationDedupCleanupRaceTest do
  @moduledoc """
  Dedup cleanup racing with a new request for the same query.

  Process 1 cancels a task (which deletes the dedup entry).
  Process 2 requests the same query and tries to claim the dedup slot.

  Invariant: process 2 either claims the slot fresh or monitors the
  holder and retries after it exits. Never deadlock, never stale entry.
  """

  alias Roux.{Cancellation, Memo}
  alias Roux.Memo.Entry

  def concuerror_options do
    [treat_as_normal: [:shutdown, :killed]]
  end

  def test do
    db = make_db()
    parent = self()
    query_key = {:q, :k}

    entry = %Entry{
      value: :result,
      hash: :erlang.phash2(:result),
      changed_at: 1,
      verified_at: 1,
      dependencies: [],
      durability: :low,
      output_entities: []
    }

    # Task process: registers and blocks until killed.
    task_pid =
      spawn(fn ->
        Cancellation.register_task(db, query_key, self())
        :ets.insert(db.dedup_table, {query_key, self()})
        send(parent, :task_ready)

        # Block until killed.
        receive do: (:never -> :ok)
      end)

    task_ref = Process.monitor(task_pid)

    # Wait for task to register before racing.
    receive do: (:task_ready -> :ok)

    # Process 1: cancels the task (clears dedup + registry).
    cancel_pid =
      spawn(fn ->
        Cancellation.cancel_all(db)
        send(parent, :cancel_done)
      end)

    cancel_ref = Process.monitor(cancel_pid)

    # Process 2: tries to claim dedup for the same query.
    requester_pid =
      spawn(fn ->
        case :ets.insert_new(db.dedup_table, {query_key, self()}) do
          true ->
            # Claimed fresh — simulate computation.
            Memo.put(db, query_key, entry)
            :ets.delete(db.dedup_table, query_key)
            send(parent, {:requester_done, :computed})

          false ->
            # Slot occupied — monitor the holder.
            case :ets.lookup(db.dedup_table, query_key) do
              [{^query_key, pid}] ->
                holder_ref = Process.monitor(pid)

                receive do
                  {:DOWN, ^holder_ref, :process, ^pid, _} ->
                    # Holder exited. Claim and compute.
                    :ets.insert(db.dedup_table, {query_key, self()})
                    Memo.put(db, query_key, entry)
                    :ets.delete(db.dedup_table, query_key)
                    send(parent, {:requester_done, :computed_after_wait})
                end

              [] ->
                # Entry was deleted between insert_new and lookup.
                :ets.insert(db.dedup_table, {query_key, self()})
                Memo.put(db, query_key, entry)
                :ets.delete(db.dedup_table, query_key)
                send(parent, {:requester_done, :computed_after_race})
            end
        end
      end)

    requester_ref = Process.monitor(requester_pid)

    # Wait for canceller.
    receive do
      :cancel_done -> :ok
      {:DOWN, ^cancel_ref, :process, ^cancel_pid, _} -> :ok
    end

    # Wait for task to die.
    receive do
      {:DOWN, ^task_ref, :process, ^task_pid, _} -> :ok
    end

    # Wait for requester.
    receive do
      {:requester_done, _} -> :ok
      {:DOWN, ^requester_ref, :process, ^requester_pid, _} -> :ok
    end

    # Memo must have the result (requester always computes).
    {:ok, memo_entry} = Memo.get(db, query_key)
    :result = memo_entry.value

    # Dedup must be clean.
    [] = :ets.lookup(db.dedup_table, query_key)

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    dedup = :ets.new(:dedup, [:set, :public, write_concurrency: true])
    waiters = :ets.new(:waiters, [:duplicate_bag, :public, write_concurrency: true])
    task_reg = :ets.new(:task_reg, [:set, :public, write_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: task_reg,
      dedup_table: dedup,
      dedup_waiters: waiters,
      intern_registry: reg,
      entity_registry: reg,
      table_owner: self(),
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.dedup_table)
    :ets.delete(db.task_registry)
    :ets.delete(db.input_registry)
  end
end

defmodule Roux.Concurrency.CancellationInputSetRaceTest do
  @moduledoc """
  Input set racing with in-flight query computation.

  Process 1 computes a query that depends on an input.
  Process 2 changes the input and calls cancel_dependents.

  Invariant: the query either completes with the old value (if it
  finished before cancellation) or is cancelled (no memo entry for
  the query). Either outcome is correct. Never partial state.
  """

  alias Roux.{Cancellation, Memo}
  alias Roux.Memo.Entry

  def concuerror_options do
    [treat_as_normal: [:shutdown, :killed]]
  end

  def test do
    db = make_db()
    parent = self()
    input_key = {:input, :source, :a}
    query_key = {:reader, :a}

    input_entry = %Entry{
      value: :old_value,
      hash: :erlang.phash2(:old_value),
      changed_at: 1,
      verified_at: 1,
      dependencies: [],
      durability: :low,
      output_entities: []
    }

    query_entry = %Entry{
      value: :computed,
      hash: :erlang.phash2(:computed),
      changed_at: 1,
      verified_at: 1,
      dependencies: [input_key],
      durability: :low,
      output_entities: []
    }

    # Pre-populate input memo so depends_on? can find deps.
    Memo.put(db, input_key, input_entry)

    # Process 1: simulates query computation.
    query_pid =
      spawn(fn ->
        Cancellation.register_task(db, query_key, self())
        :ets.insert(db.dedup_table, {query_key, self()})

        # Set up the query's memo entry (showing dep on input) so
        # cancel_dependents can discover it.
        Memo.put(db, query_key, query_entry)

        # Simulate computation completing.
        Cancellation.unregister_task(db, query_key)
        :ets.delete(db.dedup_table, query_key)

        send(parent, :query_done)
      end)

    query_ref = Process.monitor(query_pid)

    # Process 2: changes the input and cancels dependents.
    input_pid =
      spawn(fn ->
        # Simulate Input.set: update the input memo entry.
        new_input = %Entry{
          input_entry
          | value: :new_value,
            hash: :erlang.phash2(:new_value),
            changed_at: 2,
            verified_at: 2
        }

        Memo.put(db, input_key, new_input)
        Cancellation.cancel_dependents(db, input_key)

        send(parent, :input_set_done)
      end)

    input_ref = Process.monitor(input_pid)

    # Wait for input setter (never killed, always completes).
    receive do
      :input_set_done -> :ok
      {:DOWN, ^input_ref, :process, ^input_pid, _} -> :ok
    end

    # Wait for query (may be killed).
    receive do
      :query_done -> :ok
      {:DOWN, ^query_ref, :process, ^query_pid, _} -> :ok
    end

    # Invariant: query memo either has a value or doesn't.
    # If it exists, it must be well-formed. Never partial.
    case Memo.get(db, query_key) do
      {:ok, entry} ->
        :computed = entry.value

      :miss ->
        :ok
    end

    # Dedup must be clean.
    [] = :ets.lookup(db.dedup_table, query_key)

    cleanup(db)
  end

  defp make_db do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    dedup = :ets.new(:dedup, [:set, :public, write_concurrency: true])
    waiters = :ets.new(:waiters, [:duplicate_bag, :public, write_concurrency: true])
    task_reg = :ets.new(:task_reg, [:set, :public, write_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: task_reg,
      dedup_table: dedup,
      dedup_waiters: waiters,
      intern_registry: reg,
      entity_registry: reg,
      table_owner: self(),
      supervisor: self()
    }
  end

  defp cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.dedup_table)
    :ets.delete(db.task_registry)
    :ets.delete(db.input_registry)
  end
end
