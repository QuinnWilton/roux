# Implementation plan

Subsystems ordered by dependency. Each subsystem is independently testable. Build bottom-up, integrating as you go.

## Dependency graph

```
                    ┌──────────┐
                    │  Intern  │ (no deps)
                    └────┬─────┘
                         │
                    ┌────┴─────┐
                    │ Revision │ (no deps)
                    └────┬─────┘
                         │
                    ┌────┴──────┐
                    │ Telemetry │ (no deps)
                    └────┬──────┘
                         │
                    ┌────┴──────┐
               ┌────┤ Database  ├────┐
               │    └────┬──────┘    │
               │         │          │
          ┌────┴──┐  ┌───┴───┐  ┌──┴─────┐
          │ Memo  │  │ Query │  │ Entity │
          └───┬───┘  └───┬───┘  └──┬─────┘
              │          │         │
          ┌───┴───┐  ┌───┴──────┐  │
          │ Input │  │Validation│  │
          └───┬───┘  └───┬──────┘  │
              │          │         │
              └────┬─────┘─────────┘
                   │
            ┌──────┴───────┐
            │   Runtime    │◄── Cycle
            └──────┬───────┘
                   │
         ┌─────────┼─────────┐
         │         │         │
    ┌────┴────┐  ┌─┴──┐  ┌──┴──┐
    │ Cancel  │  │ GC │  │Lang │
    └─────────┘  └────┘  └──┬──┘
                             │
                    ┌────────┼────────┐
                    │                 │
              ┌─────┴─────┐   ┌──────┴────┐
              │ Compiler  │   │    LSP    │
              └───────────┘   └───────────┘
```

Note: Validation depends on Database, Memo, Revision only. It does NOT depend on Runtime — it takes an `ensure_fn` callback instead (see [D13](decisions.md)). Runtime depends on Validation and provides the callback at call time.

## Build order

Subsystems are grouped into tiers. Within a tier, subsystems can be built in any order. Each tier's subsystems are independently testable before moving to the next tier.

### Tier 0: Foundation (no Roux deps)

These are leaf modules with no dependencies on other Roux code. They can be built and tested in isolation.

| # | Subsystem | Spec | Estimated size | Key challenge |
|---|-----------|------|---------------|---------------|
| 1 | Intern | [01-intern.md](subsystems/01-intern.md) | ~100 LOC | Lock-free concurrent interning |
| 2 | Revision | [02-revision.md](subsystems/02-revision.md) | ~60 LOC | Atomics API, durability level ordering |
| 3 | Telemetry | [03-telemetry.md](subsystems/03-telemetry.md) | ~80 LOC | Consistent event schema |

### Tier 1: Storage

| # | Subsystem | Spec | Estimated size | Key challenge |
|---|-----------|------|---------------|---------------|
| 4 | Database | [04-database.md](subsystems/04-database.md) | ~150 LOC | Table lifecycle, supervisor tree, crash recovery |
| 5 | Memo | [05-memo.md](subsystems/05-memo.md) | ~120 LOC | ETS flat tuple layout, select_replace for partial updates |

### Tier 2: Query definition + validation

| # | Subsystem | Spec | Estimated size | Key challenge |
|---|-----------|------|---------------|---------------|
| 6 | Input | [06-input.md](subsystems/06-input.md) | ~100 LOC | Early cutoff at input level, revision advancement |
| 7 | Query | [07-query.md](subsystems/07-query.md) | ~200 LOC | defquery macro hygiene, registration |
| 8 | Entity | [08-entity.md](subsystems/08-entity.md) | ~250 LOC | use Roux.Entity macro, identity key interning, per-field tracking |
| 9 | Validation | [09-validation.md](subsystems/09-validation.md) | ~200 LOC | The core algorithm, durability optimization, early cutoff |

Validation belongs in this tier because it depends only on Database, Memo, and Revision — no dependency on Runtime (see [D13](decisions.md)). It takes an `ensure_fn` callback, so it can be built and tested in isolation with fake callbacks before Runtime exists.

### Tier 3: Execution engine

| # | Subsystem | Spec | Estimated size | Key challenge |
|---|-----------|------|---------------|---------------|
| 10 | Cycle | [10-cycle.md](subsystems/10-cycle.md) | ~50 LOC | Clean error messages, designing for future fixed-point |
| 11 | Runtime | [11-runtime.md](subsystems/11-runtime.md) | ~300 LOC | Execution flow, dependency recording, write buffering, dedup |

Runtime provides the `ensure_up_to_date` callback to Validation, closing the loop. This is where the full validation + re-execution cycle comes together.

**Milestone: working incremental computation.** After Tier 3, the framework can define inputs, define derived queries, execute them, change inputs, and observe correct incremental recomputation with early cutoff. This is the MVP.

### Tier 4: Lifecycle

| # | Subsystem | Spec | Estimated size | Key challenge |
|---|-----------|------|---------------|---------------|
| 12 | Cancellation | [12-cancellation.md](subsystems/12-cancellation.md) | ~150 LOC | Reverse dependency traversal, dedup table cleanup |
| 13 | GC | [13-gc.md](subsystems/13-gc.md) | ~150 LOC | Entity liveness, cascade deletion |

### Tier 5: Language layer

| # | Subsystem | Spec | Estimated size | Key challenge |
|---|-----------|------|---------------|---------------|
| 14 | Lang | [14-lang.md](subsystems/14-lang.md) | ~80 LOC | Behaviour design, extension registration |
| 15 | Mix Compiler | [15-mix-compiler.md](subsystems/15-mix-compiler.md) | ~150 LOC | Mix.Task.Compiler integration, beam output |
| 16 | LSP | [16-lsp.md](subsystems/16-lsp.md) | ~300 LOC | gen_lsp integration, position mapping, debouncing |

## Integration test milestones

### After Tier 3: "Calculator test"

Define a trivial language: inputs are expressions like `"1 + 2 * 3"`, queries parse and evaluate. Verify:
- First evaluation computes from scratch
- Re-evaluation with same input returns cached result (no re-execution)
- Changing one input re-evaluates only affected queries
- Early cutoff: `"1 + 2"` → `"2 + 1"` still evaluates to `3`, downstream unaffected

### After Tier 4: "Cancellation test"

Same setup, but with a slow query (artificial delay). Verify:
- Changing input during slow query cancels it
- No partial state after cancellation
- Re-query after cancellation produces correct result

### After Tier 5: "Compile test"

A trivial language that compiles to BEAM modules via Mix. Verify:
- `mix compile` produces .beam files
- Editing a source file recompiles only that file
- Cross-file dependencies trigger correct recompilation

## Property test strategy

The critical correctness property (implemented after Tier 3):

> For any sequence of input changes and query requests over any DAG of queries, the incremental result equals the batch (from-scratch) result.

This is a `StreamData` property test that:
1. Generates a random query DAG (N queries, random dependencies)
2. Generates random input values
3. Computes all queries (populating memos)
4. Generates random input changes
5. Computes all queries incrementally
6. Clears all memos and computes from scratch
7. Asserts incremental == from-scratch

Additional sequential properties:
- Revision monotonicity
- Dependency list completeness (every query read is recorded)
- Early cutoff correctness (changed_at only advances when value changes)
- Durability optimization correctness (never skips validation when it shouldn't)

## Concurrency testing strategy

Roux's correctness depends on concurrent ETS operations converging to identical results regardless of scheduler interleaving. We use **Concuerror** to systematically explore all interleavings for focused concurrent scenarios, and **StreamData** for randomized concurrent integration tests.

### Concuerror (exhaustive interleaving exploration)

[Concuerror](https://github.com/parapluu/Concuerror) instruments BEAM scheduling points (process spawns, message sends, ETS operations) and systematically explores all possible orderings. It asserts: no deadlocks, no crashes, and a post-condition on final state.

Concuerror tests are small, focused modules that exercise specific race conditions. They live in `test/concurrency/` and are run separately from ExUnit (Concuerror has its own runner):

```bash
mix concuerror --test Roux.Concurrency.InternTest
```

#### Scenarios to test with Concuerror

**Intern races** (Tier 0):
- N processes intern the same value simultaneously → all get the same ID
- N processes intern different values simultaneously → all get distinct IDs
- Intern + resolve racing → resolve never returns stale or partial data

**Memo table races** (Tier 1):
- Two processes validate the same stale query simultaneously → both see consistent final state
- Put racing with update_verified → no lost updates
- Put racing with get → get returns either old or new entry, never partial

**Dedup table races** (Tier 3):
- Two processes request the same uncomputed query → exactly one computes, other waits
- Compute completes while another process is checking dedup → waiter gets the result
- Cancellation races with completion → either the result is stored or it's not, never partial

**Input set + query execution races** (Tier 4):
- Input changes while a dependent query is mid-execution → query is cancelled cleanly OR completes with old value (both are correct)
- Rapid input changes → revision counter advances correctly, no skipped revisions

**Entity creation races** (Tier 2):
- Two queries create entities with the same identity key → resolved consistently

#### Concuerror integration

Concuerror tests are written as plain Erlang/Elixir modules with a `test/0` function:

```elixir
defmodule Roux.Concurrency.InternTest do
  def test do
    table = Roux.Intern.new(:test)

    # Spawn N processes that all intern the same value
    tasks =
      for _ <- 1..3 do
        spawn(fn ->
          id = Roux.Intern.intern(table, "hello")
          send(self(), {:result, id})
        end)
      end

    # Collect results
    ids = for _ <- tasks, do: receive(do: ({:result, id} -> id))

    # All must be the same
    [first | rest] = ids
    true = Enum.all?(rest, &(&1 == first))

    Roux.Intern.destroy(table)
  end
end
```

Concuerror explores all interleavings of the 3 spawned processes and verifies the assertion holds in every case.

#### Practical limits

Concuerror's state space grows exponentially with process count and scheduling points. Keep scenarios small:
- 2–3 concurrent processes per scenario
- Minimal ETS operations (isolate the race, don't test the whole framework)
- Use `--dpor optimal` for state space reduction
- Bound exploration with `--interleaving_bound` if needed

### StreamData concurrent properties (randomized)

For larger-scale concurrent testing where exhaustive exploration is impractical, use StreamData to generate random concurrent workloads:

**Convergence property**: N processes executing random queries on the same database, with random input changes interleaved, produce the same final memo state as serial execution of the same operations in any valid linearization.

```elixir
property "concurrent query execution converges" do
  check all dag <- query_dag_generator(),
            inputs <- input_sequence_generator(dag),
            operations <- concurrent_ops_generator(dag, inputs),
            max_runs: 200 do
    db = setup_database(dag)
    set_initial_inputs(db, inputs)

    # Run operations concurrently with random timing
    tasks = Enum.map(operations, fn op ->
      Task.async(fn ->
        jitter = :rand.uniform(10)
        Process.sleep(jitter)
        execute_op(db, op)
      end)
    end)
    concurrent_results = Task.await_many(tasks)

    # Run same operations serially for reference
    db_serial = setup_database(dag)
    set_initial_inputs(db_serial, inputs)
    serial_results = Enum.map(operations, &execute_op(db_serial, &1))

    # Final query results must match (order-independent)
    assert_equivalent_results(db, db_serial, dag)

    cleanup(db)
    cleanup(db_serial)
  end
end
```

**Dedup property**: N concurrent requests for the same query key result in exactly one execution (tracked via telemetry or a counter).

**No-leak property**: After concurrent execution with cancellations, no orphaned dedup entries, no orphaned task registry entries, no partial memo entries.

### Test organization

```
test/
├── concurrency/              # Concuerror test modules
│   ├── intern_test.exs
│   ├── memo_test.exs
│   ├── dedup_test.exs
│   ├── input_race_test.exs
│   └── entity_race_test.exs
├── properties/               # StreamData property tests
│   ├── validation_prop_test.exs
│   ├── convergence_prop_test.exs
│   └── concurrent_prop_test.exs
└── ...                       # Regular ExUnit tests
```

### When to run what

| Test suite | When | Time budget |
|-----------|------|------------|
| ExUnit (unit + integration) | Every commit, CI | Seconds |
| StreamData properties | Every commit, CI | 10–30 seconds |
| Concuerror scenarios | Pre-merge, CI (separate job) | Minutes |
| StreamData concurrent properties | Pre-merge, CI | 30–60 seconds |
