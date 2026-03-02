defmodule Roux.Cycle do
  @moduledoc """
  Detects cycles in the query dependency graph at runtime.

  When query A calls query B which calls query A, the framework must
  detect this and respond rather than deadlocking or stack-overflowing.
  Current behavior: abort with a clear `Roux.Cycle.Error`.

  Detection is O(n) in the query stack depth, which is bounded by the
  query DAG depth. The query stack is process-local (in the Context
  struct), so no synchronization is needed.

  ## Designing for fixed-point iteration

  The data structures support future fixed-point iteration without
  structural changes. When implemented, `check!/2` would return a
  provisional value instead of raising, and the runtime would re-execute
  the cycle until the result stabilizes. See D7 for rationale.
  """

  alias Roux.Runtime.Context

  @doc """
  Checks if the given query is already on the active stack.

  Returns `:ok` if no cycle exists. Raises `Roux.Cycle.Error` with the
  cycle path if one is detected.

  Called by Runtime before pushing a query onto the stack.
  """
  @spec check!(Context.t(), Roux.Memo.query_key()) :: :ok
  def check!(%Context{} = context, query_key) do
    case check(context, query_key) do
      :ok -> :ok
      {:cycle, cycle} -> raise Roux.Cycle.Error, cycle: cycle
    end
  end

  @doc """
  Non-raising variant of `check!/2`.

  Returns `:ok` if no cycle, or `{:cycle, path}` where `path` is the
  list of query keys forming the cycle (starting and ending with the
  repeated key).
  """
  @spec check(Context.t(), Roux.Memo.query_key()) ::
          :ok | {:cycle, [Roux.Memo.query_key()]}
  def check(%Context{query_stack: stack}, query_key) do
    if query_key in stack do
      cycle = stack |> Enum.drop_while(&(&1 != query_key)) |> Kernel.++([query_key])
      {:cycle, cycle}
    else
      :ok
    end
  end
end
