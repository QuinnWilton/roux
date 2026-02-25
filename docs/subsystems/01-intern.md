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

@spec resolve(t(), id()) :: term()
# Resolve an ID back to its value. Raises on unknown ID.

@spec resolve!(t(), id()) :: term()
# Same as resolve/2 but raises with a clear error message.

@spec lookup(t(), term()) :: {:ok, id()} | :error
# Check if a value is already interned without interning it.

@spec size(t()) :: non_neg_integer()
# Return the number of interned values.

@spec destroy(t()) :: :ok
# Delete both ETS tables. Called during database shutdown.
```

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
5. Process A does `ets.insert_new(forward, {"foo", 42})` → succeeds
6. Process B does `ets.insert_new(forward, {"foo", 43})` → fails (already exists)
7. Process B reads back `{"foo", 42}` from forward table, returns 42
8. ID 43 is "wasted" — this is acceptable, IDs need not be contiguous

This is lock-free and correct. The wasted ID is harmless.

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
