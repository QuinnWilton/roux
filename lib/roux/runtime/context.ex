defmodule Roux.Runtime.Context do
  @moduledoc """
  Threaded context passed through query execution.

  A plain struct recording the execution state for a single query call
  chain: the active query, the query stack (for cycle detection),
  accumulated dependencies, created entities, and the minimum durability
  across transitive inputs.

  This module is intentionally independent of `Roux.Runtime` — it is a
  data structure, not behavior. Cycle detection reads `query_stack`
  without any Runtime dependency.

  ## Fields

  - `db` — the database handle.
  - `active_query` — the currently executing query, or `nil` if at top level.
  - `query_stack` — stack of active queries from outermost to innermost.
    Used for cycle detection.
  - `recorded_deps` — dependencies accumulated during the current query's
    execution. Flushed to the memo entry on completion.
  - `created_entities` — entities created during the current query's
    execution. Flushed to the memo entry on completion.
  - `min_durability` — the minimum durability level seen across all inputs
    read transitively. Propagated to the memo entry for the durability
    optimization. Starts at `:high` (identity for min).
  """

  @type t :: %__MODULE__{
          db: Roux.Database.t(),
          active_query: Roux.Memo.query_key() | nil,
          query_stack: [Roux.Memo.query_key()],
          recorded_deps: [Roux.Memo.dependency()],
          created_entities: [{module(), term()}],
          min_durability: Roux.Revision.durability()
        }

  @enforce_keys [:db]
  defstruct [
    :db,
    active_query: nil,
    query_stack: [],
    recorded_deps: [],
    created_entities: [],
    min_durability: :high
  ]

  @doc """
  Creates a new context for the given database handle.
  """
  @spec new(Roux.Database.t()) :: t()
  def new(db) do
    %__MODULE__{db: db}
  end
end
