# Subsystem: Cancellation

Module: `Roux.Cancellation`

## Purpose

Cancel in-flight query computations when their inputs are invalidated mid-computation. On the BEAM, cancellation is clean: kill the process. No unwinding, no unsafety, no partial state (because writes are buffered until completion).

See decision [D3](../decisions.md) for the Task-based process model.

## Dependencies

- `Roux.Database` — task registry, dedup table
- `Roux.Memo` — dependency metadata for determining affected queries
- `Roux.Telemetry` — cancel event emission

Note: Runtime depends on Cancellation (calls `register_task`/`unregister_task` during query execution), not the other way around. See [D16](../decisions.md) for the full dependency graph.

## Key types

```elixir
# Task registry ETS entry:
# {query_key, task_pid}

# Dedup table ETS entry (managed by Runtime):
# {query_key, computing_pid}
```

## Public API

```elixir
@spec register_task(Roux.Database.t(), Roux.Memo.query_key(), pid()) :: :ok
# Register an in-flight query task. Called by Runtime when claiming a dedup slot.

@spec unregister_task(Roux.Database.t(), Roux.Memo.query_key()) :: :ok
# Remove a task registration. Called by Runtime in the after block on completion.

@spec cancel_dependents(Roux.Database.t(), Roux.Memo.query_key()) :: :ok
# Cancel all in-flight tasks that transitively depend on the given query key.
# Called when an input is set/changed.
# Walks forward from active tasks checking memo dependencies (Option A).

@spec cancel_all(Roux.Database.t()) :: :ok
# Cancel all in-flight tasks. Called on database shutdown or full reset.

@spec await_or_cancel(Roux.Database.t(), Roux.Memo.query_key(), timeout()) ::
        {:ok, term()} | :cancelled
# Wait for an in-flight task to complete, or cancel it on timeout.
```

## Runtime integration

`Roux.Runtime.compute/7` integrates with Cancellation at the dedup boundary:

1. After `claim_dedup` succeeds: `Cancellation.register_task(db, query_key, self())`.
2. In the `after` block (alongside dedup cleanup): `Cancellation.unregister_task(db, query_key)`.

When a task is killed via `Process.exit(pid, :kill)`, the `after` block does not run. `kill_task/4` manually cleans both the dedup table and task registry to compensate.

## Cancellation protocol

When an input changes and the caller wants to cancel stale in-flight work:

1. Call `Cancellation.cancel_dependents(db, {:input, input_name, key})`.
2. For each registered task, check if its memo entry's dependencies transitively include the changed key.
3. For each affected task: `Process.exit(pid, :kill)`.
4. Clean up their dedup table and task registry entries.
5. Emit `[:roux, :cancel, :task]` telemetry with reason `:input_changed`.

Cancelled tasks leave no partial state because all writes are buffered in process-local state and only flushed on successful completion.

## Reverse dependency lookup

To find which in-flight tasks depend on a changed input, we need to traverse the dependency graph. Two approaches:

### Option A: Walk forward from active tasks (implemented)
For each registered in-flight task, check if its memo entry's dependency list (transitively) includes the changed input. This is O(active_tasks * avg_dep_depth). Uses a map for cycle protection in diamond dependency graphs.

### Option B: Maintain a reverse dependency index
Store reverse edges: for each query key, which other queries depend on it. This makes cancellation O(affected_queries) but requires maintaining the index on every query execution.

**Using Option A.** The number of concurrently in-flight tasks is typically small (bounded by the number of CPU cores). Optimize to Option B only if profiling shows cancellation is a bottleneck.

## Kill mechanics

`Process.exit(pid, :kill)` is used instead of `Task.shutdown/2` because:

- No Task reference is needed (tasks are tracked by pid only).
- `:kill` is untrappable — immediate, guaranteed termination.
- The `after` block does not run, so `kill_task/4` manually cleans dedup + registry + emits telemetry.
- `Process.exit` on an already-dead pid is a no-op (idempotent).

## Telemetry reasons

- `cancel_dependents` → `:input_changed`
- `cancel_all` → `:shutdown`
- `await_or_cancel` timeout → `:timeout`

## Implementation notes

- The task registry uses `write_concurrency: true` since tasks register/unregister frequently.
- Cancellation of a task that has already completed is a no-op (the process is dead, `Process.exit` is a no-op, registry/dedup cleanup deletes nothing).
- The dedup table and task registry are separate because the dedup table has a different lifecycle (survives after task completion to serve the cached result).
- `await_or_cancel` handles the noproc race (task exits between registry lookup and `Process.monitor`) by checking the memo table before returning `:cancelled`.
- On abnormal exit in `await_or_cancel`, the registry is defensively cleaned in case the kill bypassed Runtime's `after` block.

## Testing strategy

### Unit tests
- Register task, unregister task, verify registry state
- Cancel a task, verify it is killed and dedup entry is cleaned
- Cancel dependents: direct, transitive, diamond, no-dep, empty cases
- Cancel all: all registered tasks are killed, registry + dedup clean
- Await or cancel: normal completion, timeout, crash, no-task, noproc race
- Cleanup invariants: dedup + registry cleaned, telemetry emitted with correct reasons

### Property tests (StreamData)
- `cancel_all` with N random tasks → registry and dedup empty, all pids dead
- Concurrent input changes with queries → no leaked tasks, no partial state, all memo entries well-formed

### Concuerror tests (exhaustive interleaving)
See decision [D11](../decisions.md).
- Cancellation racing with task completion → either result is stored or it's not, never partial
- Input set racing with in-flight query → query is cancelled OR completes with old value (both correct)
- Dedup cleanup racing with new request → new requester either waits for cleanup or recomputes, never sees stale dedup entry
- Cancel_dependents racing with new task registration → no missed cancellations, no double-kills
