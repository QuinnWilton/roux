# Subsystem: Telemetry

Module: `Roux.Telemetry`

## Purpose

Structured event definitions for observability and debugging. Emits `:telemetry` events for all significant framework operations. Essential for answering "why did this query re-execute?" and "why didn't this query re-execute?"

## Dependencies

None (uses the `:telemetry` library, which is an OTP dependency).

## Events

All events are prefixed with `[:roux, ...]`.

### Query lifecycle

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:roux, :query, :start]` | `system_time` | `query_name`, `key`, `revision` |
| `[:roux, :query, :stop]` | `duration` | `query_name`, `key`, `revision`, `result_hash` |
| `[:roux, :query, :exception]` | `duration` | `query_name`, `key`, `revision`, `kind`, `reason` |

### Cache operations

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:roux, :cache, :hit]` | — | `query_name`, `key`, `revision`, `changed_at`, `verified_at` |
| `[:roux, :cache, :miss]` | — | `query_name`, `key`, `revision` |
| `[:roux, :cache, :early_cutoff]` | — | `query_name`, `key`, `revision`, `changed_at` |

### Validation

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:roux, :validation, :start]` | `system_time` | `query_name`, `key`, `revision` |
| `[:roux, :validation, :stop]` | `duration` | `query_name`, `key`, `revision`, `result` (`:valid` or `:stale`) |
| `[:roux, :validation, :durability_skip]` | — | `query_name`, `key`, `durability`, `revision` |

### Other operations

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:roux, :input, :set]` | — | `input_name`, `key`, `revision`, `durability` |
| `[:roux, :input, :delete]` | — | `input_name`, `key`, `revision`, `durability` |
| `[:roux, :cycle, :detected]` | — | `query_name`, `key`, `stack` |
| `[:roux, :cancel, :task]` | — | `query_name`, `key`, `reason` |
| `[:roux, :gc, :sweep]` | `duration`, `entries_removed` | `revision` |
| `[:roux, :intern, :new]` | — | `table_name`, `id`, `value_size` |

## Public API

```elixir
@spec span(event_prefix, metadata, fun) :: result
# Wraps :telemetry.span/3 with [:roux | event_prefix].

@spec event(event_name, measurements, metadata) :: :ok
# Emits a :telemetry.execute/3 with [:roux | event_name].
```

Helper functions for each event type to ensure consistent metadata shape:

```elixir
@spec query_start(query_name, key, revision) :: :ok
@spec query_stop(query_name, key, revision, duration, result_hash) :: :ok
@spec cache_hit(query_name, key, revision, changed_at, verified_at) :: :ok
@spec cache_miss(query_name, key, revision) :: :ok
@spec early_cutoff(query_name, key, revision, changed_at) :: :ok
# ... etc
```

## Implementation notes

- Each helper function constructs the measurements and metadata maps, then calls `:telemetry.execute/3`. No logic, just consistent event shapes.
- Events should be cheap to emit when no handlers are attached (`:telemetry` handles this).
- Consider a compile-time flag or application env to disable telemetry entirely for benchmarking.

## Testing strategy

### Unit tests
- Attach a handler, perform an operation, verify the event was emitted with correct metadata
- Verify all event names match the documented schema
- Verify span events emit both start and stop
