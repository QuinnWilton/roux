# Subsystem: Validation

Module: `Roux.Validation`

## Purpose

The validation algorithm determines whether a cached memo entry is still valid by recursively checking its dependencies. This is the heart of incrementality — validation avoids recomputation when nothing has actually changed. Early cutoff is integrated here: even after recomputation, if the result hasn't changed, downstream queries are not invalidated.

## Dependencies

- `Roux.Database` — table references
- `Roux.Memo` — memo entry reads and updates
- `Roux.Revision` — revision counter and durability checks

Notably, Validation does **not** depend on Runtime. See [D13](../decisions.md).

## Public API

```elixir
@type ensure_fn :: (Roux.Database.t(), Roux.Memo.query_key() -> :ok)
# Callback that ensures a dependency is up-to-date.
# Provided by the caller (Runtime). May trigger re-execution of stale deps.
# After this returns, the dep's memo entry is guaranteed to reflect the
# current revision (either validated or re-executed with a fresh changed_at).

@spec validate(Roux.Database.t(), Roux.Memo.query_key(), ensure_fn()) :: :valid | :stale
# Determine if a memo entry's cached value is still valid.
# If valid, updates verified_at to current revision as a side effect.
# If stale, returns :stale — the caller is responsible for re-execution.
#
# The ensure_fn callback is called for each dependency that needs to be
# brought up-to-date. This breaks the circular dependency with Runtime:
# Validation doesn't know how to execute queries — it just asks the caller
# to make sure a dependency is current before checking its changed_at.
```

## The algorithm

This implements the algorithm from the design document (section 3.2), with the durability optimization integrated and the `ensure_fn` callback for dependency resolution.

```
validate(db, query_key, ensure_fn):
  entry = Memo.get(db, query_key)

  # Case 1: no memo exists
  if entry == :miss:
    return :stale

  # Case 2: already validated this revision
  current_rev = Revision.current(db.revision)
  if entry.verified_at == current_rev:
    return :valid

  # Case 3: durability optimization
  # If this query's minimum dependency durability is D, and no input
  # of durability D or higher has changed since verified_at, skip traversal.
  if Revision.last_changed_at_or_below(db.revision, entry.durability) <= entry.verified_at:
    Memo.update_verified(db, query_key, current_rev)
    emit [:roux, :validation, :durability_skip]
    return :valid

  # Case 4: walk dependencies
  for dep <- entry.dependencies:
    ensure_fn.(db, dep)  # callback: make this dep current
    dep_entry = Memo.get(db, dep)

    if dep_entry.changed_at > entry.verified_at:
      # This dependency's value changed since we last validated.
      # Our memo is stale — we need to re-execute.
      return :stale

  # All dependencies checked, none changed.
  Memo.update_verified(db, query_key, current_rev)
  return :valid
```

## How Runtime provides the callback

Runtime's `ensure_up_to_date/2` function is the natural `ensure_fn`:

```elixir
# In Roux.Runtime:
defp ensure_up_to_date(db, query_key) do
  case Roux.Validation.validate(db, query_key, &ensure_up_to_date/2) do
    :valid -> :ok
    :stale -> re_execute(db, query_key)  # re-execute and store result
  end
end

# Top-level entry point:
def execute(db, query_name, key, query_fun) do
  query_key = {query_name, key}

  case Memo.get(db, query_key) do
    {:ok, entry} when entry.verified_at == current_rev ->
      entry.value

    {:ok, _entry} ->
      ensure_up_to_date(db, query_key)
      # ... read updated memo

    :miss ->
      # ... execute from scratch
  end
end
```

The recursion is: `Runtime.ensure_up_to_date` → `Validation.validate` → `ensure_fn` (which is `ensure_up_to_date` again). The compile-time dependency is one-way: Runtime depends on Validation, not the reverse.

## Testability benefit

In tests, Validation can be tested with a fake `ensure_fn`:

```elixir
# Test that validation detects staleness without wiring up real query execution:
fake_ensure = fn _db, _dep_key -> :ok end
assert Validation.validate(db, query_key, fake_ensure) == :stale

# Test that validation calls ensure_fn for each dependency:
{:ok, agent} = Agent.start_link(fn -> [] end)
tracking_ensure = fn _db, dep_key ->
  Agent.update(agent, &[dep_key | &1])
  :ok
end
Validation.validate(db, query_key, tracking_ensure)
assert Agent.get(agent, & &1) == [{:parse, "foo.ex"}]
```

This is much simpler than setting up a full Runtime with registered queries just to test validation logic.

## Subtleties

### Dependency list changes on re-execution

When a query re-executes, it may call different queries than before (e.g., an if-branch that depends on a config flag). The new dependency list must replace the old one atomically. The Runtime handles this by writing the complete new dependency list during the flush phase.

### Validation ordering

If query A depends on both B and C, the `ensure_fn` brings each dependency up-to-date before we check its `changed_at`. This handles cascading staleness naturally:

1. `ensure_fn(db, B)` → validates B, may re-execute B if B's deps changed.
2. After return, B's memo is current. Check B's `changed_at`.
3. `ensure_fn(db, C)` → same for C.
4. If neither B nor C changed: A is valid. If either changed: A is stale.

### Early cutoff interaction

The validation algorithm checks `dep_entry.changed_at > entry.verified_at`. The `changed_at` field is NOT updated when early cutoff fires — that's the whole point. So if the `ensure_fn` re-executed dependency B but it produced the same value, B's `changed_at` stays at its old value, and A sees no change.

### Cycle during validation

Validation should never encounter a cycle because it follows the dependency graph, which is a DAG (cycles are detected and rejected during execution). If a cycle is somehow present, the `ensure_fn` callback would recurse infinitely — detect this by tracking the validation stack in the callback (Runtime's responsibility, via the Context query stack).

### Input queries during validation

Input queries have no dependencies — they are always "valid" (their `changed_at` reflects when they were last set). The `ensure_fn` for an input is a no-op: nothing to execute, just check `changed_at`.

## Durability optimization details

The durability optimization avoids walking the dependency graph entirely for queries rooted in stable inputs. The key insight:

- Each memo entry records `durability`: the minimum durability across all transitive input dependencies.
- If `durability == :high` and no `:high` input has changed since `verified_at`, the query cannot possibly be stale.
- If `durability == :medium` and no `:medium` or `:high` input has changed since `verified_at`, same.

The `last_changed_at_or_below/2` function on Revision returns the max revision across all levels at or below the given level. If this value is ≤ `verified_at`, validation can skip entirely.

## Testing strategy

### Unit tests
- Query with unchanged dependencies validates as `:valid`
- Query with changed dependency validates as `:stale`
- Query with changed dependency but early cutoff validates as `:valid`
- Durability skip: high-durability query skips validation when only low inputs changed
- Transitive validation: A → B → C, change C, validate A triggers validation of B and C
- Already validated this revision: returns `:valid` immediately

### Property tests

**The critical correctness property**: for any sequence of input changes and query requests, the incremental result equals the batch (non-incremental) result.

Formalized:
1. Generate a random DAG of queries with random computation functions.
2. Set random inputs.
3. Compute all queries (populating memos).
4. Change random inputs.
5. Compute all queries incrementally (using validation + selective re-execution).
6. Compute all queries from scratch (clearing all memos first).
7. Assert: incremental results == from-scratch results.

This is the single most important test in the entire framework.

### Stress tests
- Deep dependency chains (100+ levels)
- Wide dependency fans (query depends on 100+ inputs)
- Diamond patterns (A → B, A → C, B → D, C → D)
- Rapid input changes during validation

### Concurrent convergence property (StreamData)

The convergence extension of the critical correctness property:

> For any DAG of queries, any set of input changes, and any interleaving of concurrent query executions, the final results are identical.

This is tested by:
1. Generate a random query DAG and initial inputs.
2. Compute all queries (populating memos).
3. Generate a batch of input changes AND query requests.
4. Execute them concurrently from N processes with random timing jitter.
5. After all tasks complete, read all query results.
6. Clear all memos, replay the same inputs serially, recompute.
7. Assert: concurrent results == serial results.

This property catches:
- Validation races (two processes validating the same dependency, one sees stale while other already updated)
- Early cutoff under concurrent modification (verified_at updated by one process while another is mid-validation)
- Dependency list replacement races (new deps written while another process reads old deps)

### Concuerror tests (exhaustive interleaving)
See decision [D11](../decisions.md).
- Two processes validate the same stale query → both converge to the same verified_at
- Validation racing with input set → validation either sees old or new input, never partial
- Validation of a diamond dependency (A → B, A → C, B → D, C → D) from two processes → consistent final state
