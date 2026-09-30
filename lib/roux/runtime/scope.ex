defmodule Roux.Runtime.Scope do
  @moduledoc false

  @key {__MODULE__, :owner}

  @spec current() :: [pid()] | nil
  def current, do: Process.get(@key)

  # A worker registers before doing any work. The coordinator acknowledges it
  # only while the scope is running, and monitors every registered descendant.
  @spec join([pid()] | nil) :: :ok
  def join(nil), do: :ok

  def join(owners) do
    Enum.each(owners, &join_owner/1)
    Process.put(@key, owners)
    :ok
  end

  defp join_owner(owner) do
    ref = Process.monitor(owner)
    send(owner, {:join, self(), ref})

    receive do
      {^ref, :joined} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, ^owner, _} ->
        exit(:shutdown)
    end
  end

  @spec run(Roux.Database.t(), timeout(), (-> term())) :: {:ok, term()} | :timeout
  def run(db, timeout, fun) when timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
    caller = self()
    ref = make_ref()
    parents = current() || []
    {owner, monitor} = spawn_monitor(fn -> coordinate(db, caller, ref, timeout, fun, parents) end)

    receive do
      {^ref, {:raised, kind, reason, trace}} ->
        Process.demonitor(monitor, [:flush])
        :erlang.raise(kind, reason, trace)

      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        exit(reason)
    end
  end

  defp coordinate(db, caller, ref, timeout, fun, parents) do
    join(parents)
    Process.flag(:trap_exit, true)
    caller_ref = Process.monitor(caller)
    owner = self()

    {worker, worker_ref} =
      :erlang.spawn_opt(
        fn ->
          join([owner | parents])

          result =
            try do
              {:ok, fun.()}
            catch
              kind, reason -> {:raised, kind, reason, __STACKTRACE__}
            end

          send(owner, {:result, self(), result})
        end,
        [:link, :monitor]
      )

    deadline = if timeout == :infinity, do: :infinity, else: now() + timeout

    job = %{
      db: db,
      caller: caller,
      caller_ref: caller_ref,
      ref: ref,
      worker: worker,
      deadline: deadline
    }

    await(job, %{worker_ref => worker}, MapSet.new([worker]))
  end

  defp await(job, monitors, pids) do
    receive do
      {:join, pid, ref} ->
        {monitors, pids} = register(monitors, pids, pid)
        send(pid, {ref, :joined})
        await(job, monitors, pids)

      {:result, worker, result} when worker == job.worker ->
        finish(job, monitors, pids, result)

      {:DOWN, ref, :process, _pid, _reason} when ref == job.caller_ref ->
        finish(job, monitors, pids, :abandoned)

      {:DOWN, ref, :process, pid, reason} when is_map_key(monitors, ref) ->
        if pid == job.worker do
          finish(job, Map.delete(monitors, ref), pids, {:raised, :exit, reason, []})
        else
          await(job, Map.delete(monitors, ref), pids)
        end
    after
      remaining(job.deadline) -> finish(job, monitors, pids, :timeout)
    end
  end

  defp register(monitors, pids, pid) do
    if MapSet.member?(pids, pid),
      do: {monitors, pids},
      else: {Map.put(monitors, Process.monitor(pid), pid), MapSet.put(pids, pid)}
  end

  defp finish(job, monitors, pids, result) do
    Enum.each(monitors, fn {_, pid} -> Process.exit(pid, :kill) end)
    pids = drain(monitors, pids)
    pids = if result == :abandoned, do: MapSet.put(pids, job.caller), else: pids
    cleanup(job.db, pids)
    Process.demonitor(job.caller_ref, [:flush])
    if result != :abandoned, do: send(job.caller, {job.ref, result})
  end

  defp drain(monitors, pids) when map_size(monitors) == 0, do: pids

  defp drain(monitors, pids) do
    receive do
      {:join, pid, _ref} ->
        {monitors, pids} = register(monitors, pids, pid)
        Process.exit(pid, :kill)
        drain(monitors, pids)

      {:DOWN, ref, :process, _pid, _reason} when is_map_key(monitors, ref) ->
        drain(Map.delete(monitors, ref), pids)
    end
  end

  defp cleanup(db, pids) do
    # Exact-object deletion leaves a claim acquired by a racing waiter intact.
    for table <- [db.dedup_table, db.task_registry, db.dedup_waiters],
        {_, pid} = row <- :ets.tab2list(table),
        MapSet.member?(pids, pid) do
      :ets.delete_object(table, row)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - now(), 0)
end
