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
  """

  @type t :: %__MODULE__{
          value: term(),
          hash: integer(),
          changed_at: Roux.Revision.revision(),
          verified_at: Roux.Revision.revision(),
          dependencies: [Roux.Memo.dependency()],
          durability: Roux.Revision.durability(),
          output_entities: [{module(), term()}]
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
    :output_entities
  ]
end
