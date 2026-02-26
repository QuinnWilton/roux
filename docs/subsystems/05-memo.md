# Subsystem: Memo

Module: `Roux.Memo`

## Purpose

The memo table stores cached query results. Each entry records the computed value, when it last changed, when it was last validated, and what dependencies were read during computation. This is the data structure that makes incrementality work.

## Dependencies

- `Roux.Database` — memo table ETS reference

## Key types

```elixir
defmodule Roux.Memo do
  @type query_key :: {query_name :: atom(), key :: term()}

  @type dependency :: query_key()

  @type entry :: %__MODULE__.Entry{
    value: term(),
    hash: integer(),
    changed_at: Roux.Revision.revision(),
    verified_at: Roux.Revision.revision(),
    dependencies: [dependency()],
    durability: Roux.Revision.durability(),
    output_entities: [{module(), term()}]
  }
end
```

### Field semantics

- **value**: The cached result of the query.
- **hash**: A hash of the value, computed via `:erlang.phash2/1`. Used for fast inequality pre-check during early cutoff (see [D8](../decisions.md)).
- **changed_at**: The revision at which this value last *actually changed*. Updated only when early cutoff does not fire.
- **verified_at**: The revision at which we last confirmed this value is still valid. Updated whenever validation succeeds, even if the value didn't change.
- **dependencies**: The list of `{query_name, key}` pairs that this query read during its last execution. Replaces atomically on re-execution.
- **durability**: The minimum durability level across this query's transitive input dependencies. Used for the durability optimization during validation.
- **output_entities**: Entity instances created by this query during its last execution. Used by GC to detect stale entities.

## Public API

```elixir
@spec get(Roux.Database.t(), query_key()) :: {:ok, entry()} | :miss
# Look up a memo entry. Returns :miss if no entry exists.

@spec put(Roux.Database.t(), query_key(), entry()) :: :ok
# Store a memo entry, overwriting any existing entry.
# Called after successful query execution with buffered results.

@spec update_verified(Roux.Database.t(), query_key(), Roux.Revision.revision()) :: :ok
# Update only the verified_at field of an existing entry.
# Called when validation determines the cached value is still valid.
# Uses ETS select_replace for atomicity.

@spec delete(Roux.Database.t(), query_key()) :: :ok
# Remove a memo entry. Called during GC.

@spec delete_all(Roux.Database.t()) :: :ok
# Clear all memo entries. Called on database reset.

@spec entries(Roux.Database.t()) :: [{query_key(), entry()}]
# Return all memo entries with their keys. Used for debugging and GC sweeps.
# Includes the key so callers (e.g. GC) can identify entries for deletion.
```

## ETS layout

The memo table stores entries as:

```elixir
{query_key, value, hash, changed_at, verified_at, dependencies, durability, output_entities}
```

Using a flat tuple (not a struct) in ETS avoids the overhead of map storage and allows `ets.select_replace` for partial updates.

## Early cutoff comparison

When a query re-executes:

1. Compute `new_hash = :erlang.phash2(new_value)`.
2. If `new_hash != old_hash`: values differ. Update `changed_at` and `verified_at` to current revision. (No structural comparison needed — we know they differ.)
3. If `new_hash == old_hash`: hashes match, but could be a collision. Do structural comparison: `new_value == old_value`.
   - If equal: early cutoff. Update `verified_at` only. `changed_at` stays the same.
   - If not equal (hash collision): update both `changed_at` and `verified_at`.

This avoids O(n) structural comparison in the common "values differ" case.

## Implementation notes

- The ETS table is created by `Roux.Database` with `read_concurrency: true`.
- `update_verified/3` uses `:ets.select_replace/2` to atomically update the `verified_at` slot without reading/rewriting the entire entry.
- The `dependencies` list stores `{query_name, key}` tuples. For queries that create entities, field-level dependencies are stored as `{:entity_field, module, entity_id, field_name}`.
- The `durability` field is computed as `min(dependency durabilities)` during execution.

## Testing strategy

### Unit tests
- Put and get round-trip
- Get on missing key returns `:miss`
- Update verified_at only changes that field
- Delete removes the entry
- Delete_all clears everything

### Property tests
- For any sequence of put/get/delete operations, the table state is consistent
- Hash pre-check correctly identifies equal vs different values (test with known phash2 collisions)

### Concuerror tests (exhaustive interleaving)
See decision [D11](../decisions.md).
- Two processes validate the same stale query simultaneously → both see consistent final state
- `put` racing with `update_verified` → no lost updates, entry is always well-formed
- `put` racing with `get` → get returns either old or new entry, never a partial tuple
- `delete` racing with `get` → get returns `:miss` or the full entry, never partial
