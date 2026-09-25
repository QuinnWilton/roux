# Subsystem: Intern

Module: `Roux.Intern`

## Purpose

Bidirectional mapping from values to unique integer IDs. Makes equality comparison O(1) for interned values, which directly impacts early cutoff performance. Every string, identifier, and type that flows through the query graph should be interned as early as possible.

See decision [D10](../decisions.md) for rationale on integer IDs over atoms.

## Dependencies

None. This is a leaf subsystem with no dependencies on other Roux modules.

## Key types

```elixir
defmodule Roux.Intern do
  @type id :: pos_integer()

  @type t :: %__MODULE__{
    forward: :ets.tid(),    # value → id
    reverse: :ets.tid(),    # id → value
    counter: :atomics.atomics_ref()
  }
end
```

## Public API

```elixir
@spec new(atom()) :: t()
# Create a new intern table pair. The atom name is for debugging/inspection only
# (not used as ETS table name — tables are unnamed to avoid atom exhaustion).

@spec intern(t(), term()) :: id()
# Intern a value, returning its ID. If already interned, returns existing ID.
# Thread-safe: concurrent calls with the same value return the same ID.

@spec resolve(t(), id()) :: {:ok, term()} | :error
# Resolve an ID back to its value. Returns :error for unknown IDs.

@spec resolve!(t(), id()) :: term()
# Resolve an ID back to its value. Raises Roux.Intern.UnknownIdError on unknown ID.

@spec lookup(t(), term()) :: {:ok, id()} | :error
# Check if a value is already interned without interning it.

@spec size(t()) :: non_neg_integer()
# Return the number of interned values.

@spec destroy(t()) :: :ok
# Delete both ETS tables. Called during database shutdown.

@spec snapshot(t()) :: snapshot()
# The forward rows and the counter: %{version: 2, forward: rows, counter: n}.

@spec encode_snapshot(t()) :: encoded_snapshot()
# The forward rows encoded, and the counter: %{version: 3, forward: binary, counter: n}.
# What a manifest persists.

@spec restore(t(), snapshot() | encoded_snapshot()) :: :ok
# Restores a fresh table. Version 2 fills both tables now; version 3 leaves the rows
# pending until the table is first used.
```

## Persistence

A snapshot stores the forward table only — every value would otherwise be stored twice — and the reverse table is rebuilt from it. The forward table is the one kept because it is authoritative: an ID becomes live only when its `{value, id}` row wins `insert_new`, while the reverse table can briefly hold a losing process's orphaned ID.

A manifest persists the encoded form (`encode_snapshot/1`), and restoring it leaves the rows encoded under the reverse-table key `0` (no ID is 0) as `{:pending, encoded, counter}`. The first operation that misses — `intern/2`, `lookup/2`, `resolve/2`, or `size/1` and `snapshot/1`, which always load — decodes the rows into both tables, then looks again; a warm run that never touches the table never pays for it. The ordering that makes this safe:

1. A process that misses makes sure no rows are pending (loading them itself if they are) and only then looks again. The second lookup's answer is final; the first one's is not, because another process's load can insert the row between the first lookup and the pending check. (Concuerror found exactly that interleaving: a `resolve/2` that missed, then saw the rows loaded, returned `:error` for a restored ID.)
2. A loader inserts every row before it marks the rows loaded, so "not pending" always means "fully loaded".
3. A new value is interned only after a miss has been confirmed against a fully loaded table, so it never duplicates a restored value, and its ID (past the restored counter) never collides with a restored row.
4. Processes that miss at the same time each load the rows. The rows are identical and never rewritten afterwards, so a duplicate load changes nothing.

After the load the key holds `{:loaded, encoded, counter}`. `encode_snapshot/1` hands back the restored encoding as long as the counter still equals the restored one — every new value allocates an ID before its row appears, so an unmoved counter means the rows are exactly the restored ones — and drops it once the counter moves.

## Implementation notes

- Use `ets.insert_new/2` on the forward table to handle concurrent interning. If `insert_new` returns `false`, another process already interned the value — read it back.
- The counter is an `:atomics` reference. Use `:atomics.add_get/3` to allocate IDs without locks.
- Both ETS tables use `read_concurrency: true` since reads vastly outnumber writes in steady state.
- The forward table is keyed by the value (arbitrary term). The reverse table is keyed by the integer ID.
- Values are copied on insert/lookup (ETS copy semantics). For large values, consider interning a hash or keeping values small.

## Race condition handling

Two processes interning the same value concurrently:

1. Process A calls `intern(table, "foo")`
2. Process A does `:atomics.add_get(counter, 1, 1)` → gets ID 42
3. Process B calls `intern(table, "foo")`
4. Process B does `:atomics.add_get(counter, 1, 1)` → gets ID 43
5. Process A inserts `{42, "foo"}` into reverse, then `ets.insert_new(forward, {"foo", 42})` → succeeds
6. Process B inserts `{43, "foo"}` into reverse, then `ets.insert_new(forward, {"foo", 43})` → fails
7. Process B deletes `{43, "foo"}` from reverse (orphan cleanup), reads back `{"foo", 42}`, returns 42
8. ID 43 is skipped — IDs need not be contiguous, but no orphaned reverse entries remain

The reverse insert happens before the forward CAS so that `resolve/2` is always
consistent: the moment a value appears in the forward table, its ID is already
resolvable. On CAS failure the losing process cleans up its reverse entry.

## Testing strategy

### Unit tests
- Round-trip: `resolve(table, intern(table, value)) == value` for any value
- Idempotent: `intern(table, value) == intern(table, value)` (same ID)
- Distinct: `intern(table, a) != intern(table, b)` when `a != b`
- Lookup: returns `:error` for unknown values, `{:ok, id}` for known
- Resolve unknown: raises on unknown ID

### Property tests
- For any list of terms, interning all of them and resolving all IDs produces the original list
- IDs are unique across distinct values
- Concurrent interning of the same value from multiple processes yields the same ID

### Concuerror tests (exhaustive interleaving)
See decision [D11](../decisions.md).
- 2–3 processes intern the same value simultaneously → all get the same ID
- 2–3 processes intern different values simultaneously → all get distinct IDs
- Intern racing with resolve → resolve never returns stale or partial data
- Intern racing with lookup → lookup returns consistent results
- On a table restored from an encoded snapshot: interning a restored value, interning a new one, resolving a restored ID, looking up and snapshotting, all racing the first load → restored IDs kept, new IDs past the restored counter, snapshots consistent
