# Subsystem: Cancellation

Module: `Roux.Cancellation`

## Purpose

Cancel in-flight query computations when their inputs are invalidated mid-computation. On the BEAM, cancellation is clean: kill the process. No unwinding, no unsafety, no partial state (because writes are buffered until completion).

See decision [D3](../decisions.md) for the Task-based process model.

## Dependencies

- `Roux.Database` — task registry, dedup table
- `Roux.Runtime` — query execution
- `Roux.Memo` — dependency metadata for determining affected queries

## Key types

```elixir
# Task registry ETS entry:
# {query_key, task_pid, task_ref}

# Dedup table ETS entry:
# {query_key, :computing | {:done, value}}
```

## Public API

```elixir
@spec register_task(Roux.Database.t(), Roux.Memo.query_key(), pid(), reference()) :: :ok
# Register an in-flight query task. Called by Runtime when spawning a task.

@spec unregister_task(Roux.Database.t(), Roux.Memo.query_key()) :: :ok
# Remove a task registration. Called on task completion.

@spec cancel_dependents(Roux.Database.t(), Roux.Memo.query_key()) :: :ok
# Cancel all in-flight tasks that transitively depend on the given query key.
# Called when an input is set/changed.
# Walks the reverse dependency graph to find affected tasks.

@spec cancel_all(Roux.Database.t()) :: :ok
# Cancel all in-flight tasks. Called on database shutdown or full reset.

@spec await_or_cancel(Roux.Database.t(), Roux.Memo.query_key(), timeout()) ::
        {:ok, term()} | :cancelled
# Wait for an in-flight task to complete, or cancel it on timeout.
```

## Cancellation protocol

When `Roux.Input.set/4` detects that a value actually changed:

1. Advance the revision counter.
2. Store the new input value.
3. Call `Cancellation.cancel_dependents(db, {:input, input_name, key})`.
4. Find all in-flight tasks whose queries transitively depend on the changed input.
5. For each such task: `Task.shutdown(task_pid, :brutal_kill)`.
6. Clean up their dedup table entries.

Cancelled tasks leave no partial state because all writes are buffered in process-local state and only flushed on successful completion.

## Reverse dependency lookup

To find which in-flight tasks depend on a changed input, we need to traverse the dependency graph in reverse. Two approaches:

### Option A: Walk forward from active tasks
For each registered in-flight task, check if its memo entry's dependency list (transitively) includes the changed input. This is O(active_tasks * avg_dep_depth).

### Option B: Maintain a reverse dependency index
Store reverse edges: for each query key, which other queries depend on it. This makes cancellation O(affected_queries) but requires maintaining the index on every query execution.

**Start with Option A.** The number of concurrently in-flight tasks is typically small (bounded by the number of CPU cores). Optimize to Option B only if profiling shows cancellation is a bottleneck.

## Dedup table semantics

The dedup table prevents duplicate computation:

1. Before executing a query, `ets.insert_new(dedup_table, {query_key, :computing})`.
   - Success: we own this computation. Proceed.
   - Failure: someone else is computing. Wait for their result.
2. On completion: `ets.insert(dedup_table, {query_key, {:done, value}})`. Waiting processes read the value.
3. On cancellation: `ets.delete(dedup_table, query_key)`. The next requester will recompute.

Waiting is implemented via `:ets.lookup` polling or a per-query monitor. Prefer monitors: the computing process is monitored, and on DOWN, the waiter checks if the result is available or recomputes.

## Implementation notes

- The task registry uses `write_concurrency: true` since tasks register/unregister frequently.
- `Task.shutdown/2` with `:brutal_kill` ensures immediate termination. No graceful shutdown is needed since writes are buffered.
- Cancellation of a task that has already completed is a no-op (the task has already flushed its results).
- The dedup table and task registry are separate because the dedup table has a different lifecycle (survives after task completion to serve the cached result).

## Testing strategy

### Unit tests
- Register task, unregister task, verify registry state
- Cancel a task, verify it is killed and dedup entry is cleaned
- Cancel dependents: set up A → B → C, cancel C, verify B is cancelled
- Cancel all: all registered tasks are killed

### Integration tests
- Start a long-running query, change its input mid-execution, verify cancellation and re-execution
- Cancelled query leaves no partial state in memo table
- Two processes request the same query simultaneously: only one computes, other waits and gets the result

### Concuerror tests (exhaustive interleaving)
See decision [D11](../decisions.md).
- Cancellation racing with task completion → either result is stored or it's not, never partial
- Input set racing with in-flight query → query is cancelled OR completes with old value (both correct)
- Dedup cleanup racing with new request → new requester either waits for cleanup or recomputes, never sees stale dedup entry
- Cancel_dependents racing with new task registration → no missed cancellations, no double-kills

### Concurrent convergence (StreamData)
- Rapid input changes while queries are executing → no deadlocks, no leaked tasks, no partial state
- After concurrent execution with cancellations: task registry is empty, dedup table has no `:computing` entries, all memo entries are well-formed
