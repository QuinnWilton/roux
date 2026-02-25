# Subsystem: Revision

Module: `Roux.Revision`

## Purpose

Global revision counter and per-durability-level change tracking. The revision is a monotonically increasing integer representing a version of the world. It increments every time any input changes. Durability tracking enables skipping validation of subgraphs rooted in high-durability inputs.

See decision [D6](../decisions.md) for rationale on building durability in from the start.

## Dependencies

None. This is a leaf subsystem.

## Key types

```elixir
defmodule Roux.Revision do
  @type revision :: pos_integer()

  @type durability :: :high | :medium | :low

  @type t :: %__MODULE__{
    counter: :atomics.atomics_ref(),     # global revision counter (slot 1)
    durability: :atomics.atomics_ref()   # per-level last-changed revision (slots 1-3)
  }
end
```

Durability levels map to atomics slots:
- `:high` → slot 1
- `:medium` → slot 2
- `:low` → slot 3

## Public API

```elixir
@spec new() :: t()
# Create a new revision tracker. Initial revision is 0 (no inputs set yet).

@spec current(t()) :: revision()
# Read the current global revision. Lock-free.

@spec advance(t(), durability()) :: revision()
# Increment the global revision counter and record which durability level changed.
# Returns the new revision number.
# Called when an input is set/modified.

@spec last_changed(t(), durability()) :: revision()
# Return the revision at which the given durability level last had an input change.
# Used during validation to skip subgraphs.

@spec last_changed_at_or_below(t(), durability()) :: revision()
# Return the maximum revision across all durability levels at or below the given level.
# :low includes :low + :medium + :high changes.
# :medium includes :medium + :high changes.
# :high includes only :high changes.
# Used for the durability optimization during validation.
```

## Durability semantics

Durability classifies how often an input changes:

| Level | Typical usage | Change frequency |
|-------|--------------|-----------------|
| `:high` | Standard library, language definitions, core config | Almost never |
| `:medium` | Project source files not currently being edited | Occasionally |
| `:low` | The file currently open in the editor | Constantly |

During validation, if a query's entire dependency subgraph has minimum durability `:high`, and `last_changed(rev, :high) < query.verified_at`, the query can be validated without any graph traversal. This saves walking potentially deep dependency chains for stable inputs.

The ordering is: `:high` > `:medium` > `:low` (high durability = changes less often).

## Implementation notes

- Use `:atomics.add_get/3` for the revision counter — atomic increment, returns new value.
- Use `:atomics.put/3` for durability tracking — store the new revision at the appropriate slot.
- `last_changed_at_or_below/2` reads multiple atomics slots and returns the max. This is not atomic across slots, but that's fine — the worst case is a spurious validation (conservative, not incorrect).
- Revision starts at 0. The first `advance/2` call sets it to 1.

## Testing strategy

### Unit tests
- `current/1` returns 0 on fresh tracker
- `advance/2` increments and returns consecutive values
- `last_changed/2` returns 0 for levels that haven't changed
- `last_changed/2` returns correct revision after advance
- `last_changed_at_or_below/2` returns max across relevant levels

### Property tests
- Revision is strictly monotonically increasing across any sequence of advance calls
- `last_changed(level)` is always ≤ `current()`
- `last_changed_at_or_below(:low) >= last_changed_at_or_below(:medium) >= last_changed_at_or_below(:high)`
