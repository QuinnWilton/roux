defmodule Roux.Memo.Entry do
  @moduledoc """
  A single memo table entry recording a cached query result.

  ## Fields

  - `value` — the cached result of the query.
  - `hash` — `:erlang.phash2/1` of the value, for fast inequality pre-check
    during early cutoff.
  - `changed_at` — the revision at which this value last actually changed.
  - `verified_at` — the revision at which we last confirmed this value is
    still valid.
  - `dependencies` — `{query_name, key}` pairs read during the last execution.
  - `durability` — minimum durability level across transitive input deps.
  - `output_entities` — entity instances created by this query.
  - `code_version` — the code version of the query when it executed
    (`Roux.Query`'s `code:` and `version:`), or nil for a query without
    one. An entry whose version is not its query's current one is
    stale (`Roux.Validation`).
  - `persist` — whether and how a manifest keeps the entry: `:inline`
    (its value in the manifest), `:blob` (its value in a `Roux.Blob`
    store, the manifest holding its digest), `:none` (never kept), or
    `:transient` (never kept, nor is any entry that read it). See
    `Roux.Query`'s `store:` and `transient:`.
  """

  @typedoc "How a manifest keeps an entry; see the moduledoc."
  @type persist :: :inline | :blob | :none | :transient

  @type t :: %__MODULE__{
          value: term(),
          hash: integer(),
          changed_at: Roux.Revision.revision(),
          verified_at: Roux.Revision.revision(),
          dependencies: [Roux.Memo.dependency()],
          durability: Roux.Revision.durability(),
          output_entities: [{module(), term()}],
          code_version: binary() | nil,
          persist: persist()
        }

  @enforce_keys [
    :value,
    :hash,
    :changed_at,
    :verified_at,
    :dependencies,
    :durability,
    :output_entities
  ]
  defstruct [
    :value,
    :hash,
    :changed_at,
    :verified_at,
    :dependencies,
    :durability,
    :output_entities,
    code_version: nil,
    persist: :inline
  ]
end
