# Subsystem: Cycle detection

Module: `Roux.Cycle`

## Purpose

Detect cycles in the query dependency graph at runtime. When query A calls query B which calls query A, the framework must detect this and respond, rather than deadlocking or stack-overflowing.

Current behavior: abort with a clear error. Fixed-point iteration is designed for but not yet implemented.

See decision [D7](../decisions.md) for rationale.

## Dependencies

- `Roux.Runtime.Context` — the active query stack (struct only, not `Roux.Runtime`)

Note: `Roux.Runtime.Context` is a plain struct definition with no behavioral dependency on `Roux.Runtime`. Elixir nested module names are naming conventions, not actual nesting — `Roux.Runtime.Context` is a fully independent module. Cycle reads the `query_stack` field; it never calls any Runtime function.

## Public API

```elixir
@spec check!(Roux.Runtime.Context.t(), Roux.Memo.query_key()) :: :ok
# Check if the given query is already on the active stack.
# If not, returns :ok (no cycle).
# If yes, raises Roux.CycleError with the cycle path.

@spec check(Roux.Runtime.Context.t(), Roux.Memo.query_key()) ::
        :ok | {:cycle, [Roux.Memo.query_key()]}
# Non-raising variant. Returns the cycle path if detected.
```

## CycleError

```elixir
defmodule Roux.CycleError do
  defexception [:cycle]

  # cycle is a list of query_keys forming the cycle,
  # e.g., [{:typecheck, "a.ex"}, {:resolve, "b.ex"}, {:typecheck, "a.ex"}]

  @impl true
  def message(%{cycle: cycle}) do
    path = cycle |> Enum.map(&inspect/1) |> Enum.join(" → ")
    "Cycle detected in query graph: #{path}"
  end
end
```

## Detection mechanism

The query stack in `Roux.Runtime.Context` records every query that is currently executing in the current process. Before executing a query, the Runtime calls `Roux.Cycle.check!/2`:

```elixir
# In Roux.Runtime.execute/4:
Roux.Cycle.check!(context, {query_name, key})
context = push_stack(context, {query_name, key})
result = query_fun.(db, key)
context = pop_stack(context)
```

If `{query_name, key}` is already on the stack, a cycle exists.

## Designing for fixed-point iteration

The data structures support future fixed-point iteration without structural changes:

1. **The query stack already exists.** Fixed-point iteration uses it to detect the cycle-closing edge.
2. **Memo entries can store provisional values.** A future `provisional: true` flag on memo entries would mark values that are not yet stable.
3. **The validation algorithm handles re-execution.** Fixed-point iteration is repeated re-execution until convergence.

When fixed-point iteration is implemented, `check!/2` would return a **provisional value** (bottom of the lattice) instead of raising, and the runtime would re-execute the cycle until the result stabilizes.

### What needs to be added later (not now)
- A lattice protocol: `bottom/0`, `join/2`, `equal?/2` for the value domain
- Provisional memo entries with a `provisional: true` flag
- A re-execution loop in Runtime that detects when the cycle has stabilized
- A maximum iteration count to prevent infinite loops

## Implementation notes

- Cycle detection is O(n) in the stack depth, which is bounded by the query DAG depth. This is fast enough.
- The query stack is process-local (in the Context struct), so no synchronization is needed.
- For cross-process cycle detection (async queries): this is not needed in v1 because nested queries execute inline (same process). If async sub-queries are added later, cycle detection would need a shared structure.

## Testing strategy

### Unit tests
- No cycle: query A → query B → query C (no error)
- Direct cycle: query A → query A (raises CycleError)
- Indirect cycle: query A → query B → query A (raises CycleError)
- Error message includes the full cycle path
- Non-raising variant returns the cycle path

### Integration tests
- Define queries that form a cycle, execute, verify CycleError is raised
- Cycle error message is clear and actionable
