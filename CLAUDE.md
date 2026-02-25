# roux

A Salsa-inspired framework for incremental, demand-driven computation on the BEAM. Domain-agnostic core with a thin `Roux.Lang` convention layer for building compilers and language tooling.

## What it does

Roux models computation as a graph of memoized queries. When inputs change, only the affected subgraph recomputes. Early cutoff prevents cascading invalidation when intermediate results haven't actually changed. The framework handles dependency tracking, cache invalidation, and concurrency. Users write pure query functions.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the full overview. Key design decisions are in [docs/decisions.md](docs/decisions.md).

### Module map

```
Roux.Intern          — bidirectional value ↔ integer ID tables
Roux.Revision        — global revision counter + durability tracking
Roux.Telemetry       — structured observability events
Roux.Database        — central handle struct, ETS lifecycle
Roux.Database.Heir   — ETS table preservation across crashes
Roux.Database.TableOwner — ETS table ownership
Roux.Memo            — memo entry storage (the cache)
Roux.Input           — input queries (external values)
Roux.Query           — derived query definition + defquery macro
Roux.Runtime         — query execution engine + dependency tracking
Roux.Runtime.Context — threaded context passed through query calls
Roux.Validation      — validation algorithm + early cutoff
Roux.Entity          — tracked structs with identity + field tracking
Roux.Cycle           — cycle detection
Roux.Cancellation    — process-based cancellation via Task
Roux.GC              — garbage collection of stale entries
Roux.Lang            — language behaviour
Roux.Lang.Compiler   — Mix compiler integration
Roux.Lang.LSP        — generic LSP adapter (gen_lsp)
```

### Subsystem docs

Each subsystem is specified in `docs/subsystems/`:

- [01-intern.md](docs/subsystems/01-intern.md) — interning
- [02-revision.md](docs/subsystems/02-revision.md) — revision tracking + durability
- [03-telemetry.md](docs/subsystems/03-telemetry.md) — observability events
- [04-database.md](docs/subsystems/04-database.md) — database handle + ETS lifecycle
- [05-memo.md](docs/subsystems/05-memo.md) — memo table
- [06-input.md](docs/subsystems/06-input.md) — input queries
- [07-query.md](docs/subsystems/07-query.md) — derived queries + defquery macro
- [08-entity.md](docs/subsystems/08-entity.md) — entity system
- [09-validation.md](docs/subsystems/09-validation.md) — validation algorithm + early cutoff
- [10-cycle.md](docs/subsystems/10-cycle.md) — cycle detection
- [11-runtime.md](docs/subsystems/11-runtime.md) — execution engine
- [12-cancellation.md](docs/subsystems/12-cancellation.md) — task cancellation
- [13-gc.md](docs/subsystems/13-gc.md) — garbage collection
- [14-lang.md](docs/subsystems/14-lang.md) — language behaviour
- [15-mix-compiler.md](docs/subsystems/15-mix-compiler.md) — Mix compiler integration
- [16-lsp.md](docs/subsystems/16-lsp.md) — LSP adapter

## Key invariants

1. Memo entries are never partial — all writes are buffered and flushed atomically.
2. Source positions never participate in early cutoff comparison.
3. Interned values use integer IDs, never atoms.
4. The revision counter is monotonically increasing.
5. Query functions must be pure (no side effects beyond calling other queries).

## Development commands

```bash
mix test                      # run all tests
mix format                    # format code
mix format --check-formatted  # check formatting
mix credo --strict            # lint
mix dialyzer                  # static analysis
```

## Commit message style

```
[component] brief description

Optional longer explanation.
```

Component names match subsystem names: `intern`, `revision`, `telemetry`, `database`, `memo`, `input`, `query`, `runtime`, `validation`, `entity`, `cycle`, `cancellation`, `gc`, `lang`, `mix-compiler`, `lsp`.

## Testing conventions

- Unit tests mirror `lib/` structure in `test/`.
- Test support modules go in `test/support/`.
- Example language implementations go in `test/support/languages/`.
- Use `stream_data` for property-based testing.
- The critical correctness property: for any sequence of input changes and query requests, the incremental result equals the batch (from-scratch) result.

## Changelog

Every user-visible change must have an entry in `CHANGELOG.md` under an `## Unreleased` section at the top.
