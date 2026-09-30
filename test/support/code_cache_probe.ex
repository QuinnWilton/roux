defmodule Roux.Test.CodeCacheProbe do
  @moduledoc false

  alias Roux.Code, as: RouxCode

  @root Roux.Test.VersionedHelper

  @spec concurrent() :: {non_neg_integer(), boolean(), boolean()}
  def concurrent do
    RouxCode.forget()
    parent = self()
    count = :atomics.new(1, [])

    exclude = fn module ->
      if module == @root do
        :atomics.add(count, 1, 1)
        send(parent, {:computing, self()})

        receive do
          :resume -> :ok
        end
      end

      false
    end

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, :started)
          RouxCode.closure([@root], exclude: exclude)
        end)
      end

    for _ <- tasks do
      receive do
        :started -> :ok
      end
    end

    receive do
      {:computing, _pid} -> :ok
    end

    overlap? =
      receive do
        {:computing, _pid} -> true
      after
        50 -> false
      end

    for task <- tasks, do: send(task.pid, :resume)
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    {:atomics.get(count, 1), length(Enum.uniq(results)) == 1, overlap?}
  end

  @spec owner_exit() :: {term(), non_neg_integer()}
  def owner_exit do
    RouxCode.forget()
    parent = self()
    count = :atomics.new(1, [])

    exclude = fn module ->
      if module == @root and :atomics.add_get(count, 1, 1) == 1 do
        send(parent, :owner_computing)

        receive do
          :never_sent -> :ok
        end
      end

      false
    end

    {owner, monitor} =
      spawn_monitor(fn -> RouxCode.closure([@root], exclude: exclude) end)

    receive do
      :owner_computing -> :ok
    end

    waiter = Task.async(fn -> RouxCode.closure([@root], exclude: exclude) end)
    Process.exit(owner, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^owner, :killed} -> :ok
    end

    {Task.await(waiter, 10_000), :atomics.get(count, 1)}
  end

  @spec nested() :: term()
  def nested do
    RouxCode.forget()

    exclude = fn _module ->
      {:ok, [{__MODULE__.Absent, :absent}]} = RouxCode.closure([__MODULE__.Absent])
      false
    end

    RouxCode.digest([@root], exclude: exclude)
  end

  @spec cross_calls() :: [term()]
  def cross_calls do
    RouxCode.forget()
    parent = self()

    tasks =
      for root <- [@root, __MODULE__.Other] do
        Task.async(fn ->
          Process.put({__MODULE__, :parent}, parent)
          RouxCode.closure([root], exclude: &__MODULE__.cross_exclude/1)
        end)
      end

    for _ <- tasks do
      receive do
        :outer_computing -> :ok
      end
    end

    for task <- tasks, do: send(task.pid, :continue)
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  @spec cross_exclude(module()) :: false
  def cross_exclude(module) do
    unless Process.get({__MODULE__, :nested}, false) do
      Process.put({__MODULE__, :nested}, true)
      send(Process.get({__MODULE__, :parent}), :outer_computing)

      receive do
        :continue -> :ok
      end

      other = if module == @root, do: __MODULE__.Other, else: @root
      {:ok, _} = RouxCode.closure([other], exclude: &__MODULE__.cross_exclude/1)
    end

    false
  end

  @spec root_reads() :: non_neg_integer()
  def root_reads do
    RouxCode.forget()
    :erlang.trace_pattern({:code, :root_dir, 0}, true, [:call_count])

    try do
      {:ok, _} = RouxCode.closure([@root])
      {:ok, _} = RouxCode.closure([@root, __MODULE__.Absent])
      {:call_count, count} = :erlang.trace_info({:code, :root_dir, 0}, :call_count)
      count
    after
      :erlang.trace_pattern({:code, :root_dir, 0}, false, [:call_count])
    end
  end
end

defmodule Roux.Test.CodeCacheProbe.Other do
  @moduledoc false

  @spec run() :: :ok
  def run, do: :ok
end
