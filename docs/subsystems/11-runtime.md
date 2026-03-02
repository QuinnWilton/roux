# Subsystem: Runtime

Modules: `Roux.Runtime`, `Roux.Runtime.Context`

## Purpose

The query execution engine. Handles memoization checks, dependency tracking, task spawning, and write buffering. This is the core integration point where queries, memos, validation, and entities come together.

See decision [D3](../decisions.md) for the Task-per-invocation model.

## Dependencies

- `Roux.Database` — table references, query and input registry lookups
- `Roux.Memo` — memo entry storage
- `Roux.Input` — reading input values via `input/3`
- `Roux.Revision` — current revision reads
- `Roux.Validation` — staleness checks (one-way: Runtime calls Validation, see [D13](../decisions.md))
- `Roux.Telemetry` — query lifecycle events
- `Roux.Cycle` — cycle detection
- `Roux.Runtime.Context` — threaded context struct for query execution state

## Key types

```elixir
defmodule Roux.Runtime.Context do
  @type t :: %__MODULE__{
    db: Roux.Database.t(),
    active_query: Roux.Memo.query_key() | nil,
    query_stack: [Roux.Memo.query_key()],
    recorded_deps: [Roux.Memo.dependency()],
    created_entities: [{module(), term()}],
    min_durability: Roux.Revision.durability()
  }
end
```

### Context fields

- **db**: The database handle.
- **active_query**: The currently executing query (for dependency recording).
- **query_stack**: Stack of active queries from outermost to innermost. Used for cycle detection.
- **recorded_deps**: Dependencies accumulated during the current query's execution. Flushed to the memo entry on completion.
- **created_entities**: Entities created during the current query's execution. Flushed to the memo entry on completion.
- **min_durability**: The minimum durability level seen across all inputs read transitively. Propagated to the memo entry for the durability optimization.

## Public API

```elixir
@spec execute(Roux.Database.t(), query_name, key, query_fun) :: term()
# The main entry point for query execution. Called by defquery-generated functions.
#
# Algorithm:
# 1. Check memo table for existing entry.
# 2. If memo exists and verified_at == current_revision: return cached value.
# 3. If memo exists and stale: validate via Roux.Validation.
#    - If valid: update verified_at, return cached value.
#    - If stale: proceed to step 4.
# 4. Execute the query function in a new context.
# 5. Compare result to old value (if exists) for early cutoff.
# 6. Flush results to ETS atomically.
# 7. Return the value.

@spec query(Roux.Database.t(), query_name, key) :: term()
# Call a derived query from within another query. Records a dependency.
# Executes inline (same process) to share the context.
# This is the function available inside defquery blocks.

@spec input(Roux.Database.t(), input_name, key) :: term()
# Read an input value from within a query. Records a dependency.

@spec parallel(Roux.Database.t(), [{query_name, key}]) :: [term()]
# Execute multiple independent queries concurrently from within a query body.
# Spawns a Task per query, collects results, and merges all recorded
# dependencies and created entities back into the parent context.
# Returns results in the same order as the input list.
# Each sub-query records its own deps; all are merged into the parent.

@spec record_dependency(Roux.Runtime.Context.t(), Roux.Memo.query_key()) :: Roux.Runtime.Context.t()
# Record that the current query depends on another query.
# Called internally by query/3 and input/3.
```

## Execution flow

```
execute(db, :typecheck, "foo.ex", fun)
│
├─ Memo exists, verified_at == current_revision?
│  └─ YES → return cached value (cache hit)
│
├─ Memo exists, verified_at < current_revision?
│  └─ Validate via Roux.Validation.validate(db, key, &ensure_up_to_date/2)
│     │  Validation calls ensure_up_to_date for each dependency,
│     │  which recursively validates/re-executes as needed.
│     ├─ :valid → update verified_at, return cached
│     └─ :stale → fall through to re-execute
│
├─ No memo or stale?
│  └─ Check dedup table: is someone else computing this?
│     ├─ YES → wait for their result
│     └─ NO → claim the slot, execute:
│
│        1. Push query onto stack (cycle detection)
│        2. Create fresh Context
│        3. Execute query_fun(db, key)
│           └─ Body calls query/3, input/3 → records deps in context
│        4. Pop query from stack
│        5. Compare result to old memo (early cutoff)
│        6. Flush: write memo entry + deps + entities to ETS
│        7. Clear dedup slot
│        8. Return value
```

### The `ensure_up_to_date` callback

Runtime provides this function to Validation as the `ensure_fn` callback. It is the glue between the two modules:

```elixir
defp ensure_up_to_date(db, query_key) do
  case Roux.Validation.validate(db, query_key, &ensure_up_to_date/2) do
    :valid -> :ok
    :stale -> re_execute(db, query_key)
  end
end
```

The recursion flows: `ensure_up_to_date` → `Validation.validate` → `ensure_fn` (for each dep) → `ensure_up_to_date` again. The compile-time dependency is one-way: Runtime → Validation. Validation never imports Runtime.

## Concurrency model

See decision [D14](../decisions.md).

Three calling contexts, three behaviors:

| Context | Function | Behavior |
|---------|----------|----------|
| Top-level (outside any query) | `execute/4` | Synchronous, concurrent-safe. Callers bring their own concurrency via `Task.async_stream` etc. |
| Nested (inside a query body) | `query/3` | Inline, same process. Shares context for dependency tracking. |
| Fan-out (inside a query body, N independent sub-queries) | `parallel/2` | Spawns tasks, merges deps back into parent context. |

### Top-level concurrency

`execute/4` is always synchronous from the caller's perspective — it blocks until the result is available. The framework is concurrent-safe internally: if another process is already computing the same query, the caller waits for that result via the dedup table.

Callers own their own concurrency. The Mix compiler does:

```elixir
files
|> Task.async_stream(fn f -> Roux.Runtime.execute(db, :compile, f, &compile_fn/2) end)
|> Enum.to_list()
```

No special framework API needed. This is the BEAM-native model — the framework doesn't decide when to spawn, the caller does.

### Nested queries

`query/3` inside a query body executes inline (same process). This is required because:
1. The dependency must be recorded in the parent's context.
2. The parent needs the result to continue.
3. The query stack (for cycle detection) must be shared.

### Fan-out with `parallel/2`

For independent sub-queries within a query body, `parallel/2` spawns tasks and merges results:

```elixir
defquery :typecheck_module, key: mod do
  functions = query(db, :parse, mod)

  types = parallel(db, Enum.map(functions, &{:typecheck_function, &1}))
  # types is [type1, type2, ...] in same order as functions

  # Can also mix query types:
  [resolved, config] = parallel(db, [
    {:resolve_imports, mod},
    {:load_config, mod}
  ])
end
```

#### `parallel/2` implementation

1. Snapshot the parent context's query stack (for cycle detection in children).
2. Spawn a `Task` per `{query_name, key}` pair. Each task runs with its own `Context` initialized with the parent's query stack.
3. Each task executes the query (may hit cache, validate, or compute from scratch).
4. Each task returns `{value, recorded_deps, created_entities, min_durability}`.
5. Parent collects all results, merges all deps and entities into its own context.
6. Return values in input order.

Dependencies from all sub-queries become dependencies of the parent query. This is correct — if any sub-query's result changes on the next revision, the parent must re-execute.

#### Cancellation interaction

If the parent query is cancelled (task killed), all `parallel` sub-tasks are also killed (they are linked or monitored by the parent). No partial state leaks because all writes are buffered.

## Write buffering

All writes during query execution are buffered in the `Context` struct (which lives on the process heap):

- Memo entry (value, hash, changed_at, verified_at)
- Dependency list
- Created entities

On successful completion, these are flushed to ETS in a single batch. If the process is killed (cancellation), nothing is written.

The flush is NOT truly atomic (ETS doesn't support multi-key transactions), but it's safe because:
1. The dedup table entry prevents other processes from computing the same query concurrently.
2. The memo entry is written last, after dependencies and entities.
3. Readers check `verified_at` before using a memo entry.

## Implementation notes

- The `db` parameter is the database handle — it is NOT the context carrier. Runtime uses the process dictionary (`{Roux.Runtime, :context}`) to thread the `Context` struct through query execution. This is an internal implementation detail; users only see the `db` parameter. The process dictionary is used because `execute/4` needs to save/restore context across nested calls without threading it through user-facing `query_fun` callbacks. This is a pragmatic deviation from D1's "explicit `db` parameter" — `db` is still threaded for users, but the internal execution context is process-local.
- `query/3` inside a query body dispatches inline (same process) to the registered defquery wrapper, which calls `execute/4`. Dependency recording and durability propagation happen in `execute/4`, not `query/3`, to avoid double-recording.
- `parallel/2` is the only place the framework spawns tasks during query execution. Sub-task contexts are initialized with the parent's query stack but empty dep/entity lists. Results are merged on join.
- During validation, `re_execute/2` needs the query function to re-run stale queries. It checks the process dictionary first (populated by `execute/4` for closure-based queries) then falls back to the query registry.

## Testing strategy

### Unit tests
- Execute a query with no memo → computes and stores result
- Execute a query with valid memo → returns cached value
- Execute a query with stale memo → recomputes
- Dependency recording: query A calls query B, verify A's deps include B
- Write buffering: kill process mid-execution, verify no partial state in ETS

### Integration tests
- Chain of queries: A → B → C, change C's input, verify A and B re-execute
- Early cutoff: A → B → C, change C's input but B produces same result, verify A does NOT re-execute
- Diamond dependency: A depends on B and C, both depend on D. Change D, verify A re-executes only once.
- `parallel/2`: fan-out over N sub-queries, verify all deps merged into parent
- `parallel/2`: sub-query hits cache, verify result returned without re-execution
- `parallel/2`: parent cancelled mid-fan-out, verify all sub-tasks killed, no partial state
- Top-level concurrency: N callers `Task.async_stream` over `execute/4`, verify dedup (only one computation per unique query key)

### Property tests
- For any DAG of queries with random input changes, the framework produces the same result as batch (non-incremental) recomputation

### Concuerror tests (exhaustive interleaving)
See decision [D11](../decisions.md).
- Two processes request the same uncomputed query → exactly one computes (dedup), other gets the result
- Compute completion racing with dedup lookup → waiter either waits or recomputes, never misses
- Write buffering: kill process at any interleaving point during execution → no partial state in ETS

### Concurrent convergence property (StreamData)
See [implementation plan](../implementation-plan.md) for full details.
- N processes executing random queries with interleaved input changes produce the same final memo state as serial execution of the same operations in any valid linearization
- No orphaned dedup entries, no orphaned task registry entries after concurrent execution with cancellations
