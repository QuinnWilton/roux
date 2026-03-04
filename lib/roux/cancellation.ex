defmodule Roux.Cancellation do
  @moduledoc """
  Process-based cancellation of in-flight query computations.

  On the BEAM, cancellation is clean: `Process.exit(pid, :kill)` terminates
  the process immediately. No unwinding, no partial state — writes are
  buffered until successful completion, so killed tasks leave no trace in
  the memo table.

  ## Cancellation protocol

  When an input changes, the caller invokes `cancel_dependents/2` with the
  input's query key. This walks forward from all active tasks, checking
  whether each task's memo entry transitively depends on the changed key.
  Affected tasks are killed and their dedup/registry entries cleaned up.

  This is Option A from the subsystem spec: forward walk from active tasks.
  The number of active tasks is bounded by CPU cores, and dependency depth
  is typically 3-5, making this efficient in practice.

  See D3 for the Task-based process model.
  """

  alias Roux.{Database, Memo, Telemetry}
  alias Roux.Memo.Entry

  @doc """
  Registers an in-flight query task in the task registry.

  Called by Runtime when spawning a task for query execution.
  Overwrites any previous registration for the same key.
  """
  @spec register_task(Database.t(), Memo.query_key(), pid()) :: :ok
  def register_task(%Database{task_registry: reg}, query_key, pid)
      when is_pid(pid) do
    :ets.insert(reg, {query_key, pid})
    :ok
  end

  @doc """
  Removes a task registration from the task registry.

  Called on task completion. No-op if no registration exists for the key.
  """
  @spec unregister_task(Database.t(), Memo.query_key()) :: :ok
  def unregister_task(%Database{task_registry: reg}, query_key) do
    :ets.delete(reg, query_key)
    :ok
  end

  @doc """
  Cancels all in-flight tasks that transitively depend on the given query key.

  Called when an input is set or changed. For each registered task, checks
  whether its memo entry's dependencies transitively include the target key.
  Affected tasks are killed with `Process.exit(pid, :kill)`.

  Uses telemetry reason `:input_changed`.
  """
  @spec cancel_dependents(Database.t(), Memo.query_key()) :: :ok
  def cancel_dependents(%Database{task_registry: reg} = db, target_key) do
    reg
    |> :ets.tab2list()
    |> Enum.each(fn {query_key, pid} ->
      if depends_on?(db, query_key, target_key, %{}) do
        kill_task(db, query_key, pid, :input_changed)
      end
    end)

    :ok
  end

  @doc """
  Cancels all in-flight tasks. Called on database shutdown or full reset.

  Uses telemetry reason `:shutdown`.
  """
  @spec cancel_all(Database.t()) :: :ok
  def cancel_all(%Database{task_registry: reg} = db) do
    reg
    |> :ets.tab2list()
    |> Enum.each(fn {query_key, pid} ->
      kill_task(db, query_key, pid, :shutdown)
    end)

    :ok
  end

  @doc """
  Waits for an in-flight task to complete, or cancels it on timeout.

  Looks up the task pid from the task registry and monitors it. Returns
  `{:ok, value}` if the task completes and leaves a memo entry, or
  `:cancelled` if the task is killed, crashes, or times out.

  Handles the race condition where a task completes between registry
  lookup and `Process.monitor` (`:noproc` DOWN message) by checking
  the memo table before returning `:cancelled`.

  If no task is registered, checks the memo table directly.
  """
  @spec await_or_cancel(Database.t(), Memo.query_key(), timeout()) ::
          {:ok, term()} | :cancelled
  def await_or_cancel(%Database{task_registry: reg} = db, query_key, timeout) do
    case :ets.lookup(reg, query_key) do
      [{^query_key, pid}] ->
        ref = Process.monitor(pid)
        await_task(db, query_key, pid, ref, timeout)

      [] ->
        # No task running — check if memo already has the result.
        check_memo(db, query_key)
    end
  end

  # -- Private: await helpers --

  defp await_task(db, query_key, pid, ref, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        # Task completed normally. Runtime's after block cleaned the
        # registry. Check memo for the result.
        check_memo(db, query_key)

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        # Task was killed or crashed. Clean up registry in case the
        # kill bypassed Runtime's after block (e.g. external :kill).
        unregister_task(db, query_key)

        # Check memo in case it completed between our registry lookup
        # and the kill signal.
        case Memo.get(db, query_key) do
          {:ok, %Entry{value: value}} -> {:ok, value}
          :miss -> :cancelled
        end
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        kill_task(db, query_key, pid, :timeout)
        :cancelled
    end
  end

  defp check_memo(db, query_key) do
    case Memo.get(db, query_key) do
      {:ok, %Entry{value: value}} -> {:ok, value}
      :miss -> :cancelled
    end
  end

  # -- Private: kill + cleanup --

  defp kill_task(db, query_key, pid, reason) do
    Process.exit(pid, :kill)

    # Manual cleanup since :kill is untrappable — after blocks don't run.
    :ets.delete(db.dedup_table, query_key)
    :ets.delete(db.task_registry, query_key)

    {query_name, key} = decompose_query_key(query_key)
    Telemetry.cancel_task(query_name, key, reason)
  end

  # -- Private: transitive dependency check --

  defp depends_on?(_db, query_key, target_key, _visited)
       when query_key == target_key do
    true
  end

  defp depends_on?(db, query_key, target_key, visited) do
    if is_map_key(visited, query_key) do
      false
    else
      visited = Map.put(visited, query_key, true)

      case Memo.get(db, query_key) do
        {:ok, %Entry{dependencies: deps}} ->
          Enum.any?(deps, fn dep ->
            depends_on?(db, dep, target_key, visited)
          end)

        :miss ->
          false
      end
    end
  end

  # -- Private: query key decomposition for telemetry --

  defp decompose_query_key({:input, name, key}), do: {name, key}
  defp decompose_query_key({name, key}), do: {name, key}
end
