defmodule Roux.Cycle.Error do
  @moduledoc """
  Raised when a cycle is detected in the query dependency graph.

  The `cycle` field contains the full cycle path as a list of query keys,
  starting and ending with the same key. For example,
  `[{:typecheck, "a.ex"}, {:resolve, "b.ex"}, {:typecheck, "a.ex"}]`
  means typecheck called resolve which called typecheck again.
  """

  @type t :: %__MODULE__{
          cycle: [Roux.Memo.query_key()]
        }

  defexception [:cycle]

  @impl true
  def message(%__MODULE__{cycle: cycle}) do
    path = Enum.map_join(cycle, " → ", &inspect/1)
    "cycle detected in query graph: #{path}"
  end
end
