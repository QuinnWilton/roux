# Roux architecture

Roux is a Salsa-inspired framework for incremental, demand-driven computation on the BEAM. It provides memoization, automatic dependency tracking, fine-grained cache invalidation, and early cutoff optimization. Roux is domain-agnostic — it has no knowledge of compilers or languages.

`Roux.Lang` is a thin convention layer that defines what it means to be a "language" in the BEAM ecosystem: a behaviour, Mix compiler integration, and a generic LSP adapter (via `gen_lsp`).

## Core idea

A computation is modeled as a graph of **queries**. Queries are pure functions from keys to values. The framework memoizes results and tracks which queries read which other queries. When an input changes, only the affected subgraph recomputes — and even then, if a recomputed query produces the same result as before (**early cutoff**), its downstream dependents are not invalidated.

## System layers

```
┌─────────────────────────────────────────────┐
│ Layer 4: Languages (user-defined)           │
│   parsers, type checkers, optimizers        │
│   implemented as Roux queries               │
├─────────────────────────────────────────────┤
│ Layer 3: Convention (Roux.Lang)             │
│   language behaviour, Mix compiler shim,    │
│   LSP adapter, cross-language interface     │
├─────────────────────────────────────────────┤
│ Layer 2: Framework (Roux)                   │
│   query registration, dependency tracking,  │
│   memoization, validation, early cutoff,    │
│   entities, interning, cancellation, GC     │
├─────────────────────────────────────────────┤
│ Layer 1: Storage                            │
│   ETS tables, :atomics, :persistent_term    │
└─────────────────────────────────────────────┘
```

## Module map

```
Roux.Intern          — bidirectional value ↔ integer ID tables
Roux.Revision        — global revision counter + durability tracking
Roux.Telemetry       — structured event definitions
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
Roux.Cycle           — cycle detection (aborts; fixed-point planned)
Roux.Cancellation    — process-based cancellation via Task
Roux.GC              — garbage collection of stale memo/entity entries
Roux.Lang            — language behaviour
Roux.Lang.Compiler   — Mix compiler integration
Roux.Lang.LSP        — generic LSP adapter (gen_lsp)
```

## Dependency graph between subsystems

```
Intern ─────────────────────────────────────────┐
Revision ───────────────────────────────────────┤
Telemetry ──────────────────────────────────────┤
                                                │
Database ◄── Intern, Revision, Telemetry        │
Memo ◄── Database                               │
Input ◄── Database, Revision, Memo, Telemetry   │
Query ◄── Database                              │
Runtime ◄── Database, Memo, Query, Validation,  │
            Telemetry, Cycle                    │
Validation ◄── Database, Memo, Revision (no     │
               Runtime dep — callback injection)│
Entity ◄── Database, Intern                     │
Cycle ◄── Runtime.Context                       │
Cancellation ◄── Database, Runtime, Memo        │
GC ◄── Database, Memo, Entity                   │
                                                │
Lang ◄── Database, Query, Input                 │
Lang.Compiler ◄── Lang, Database, Input         │
Lang.LSP ◄── Lang, Database (+ gen_lsp)         │
```

## Storage architecture

| Component | Storage | Rationale |
|-----------|---------|-----------|
| Revision counter | `:atomics` (single integer) | Lock-free reads from any process |
| Memo table | ETS `:set` with `read_concurrency: true` | Concurrent reads from query tasks |
| Dependency metadata | Same ETS table as memo entries | Single-hop lookups |
| Intern tables | Dedicated ETS `:set` per interned type | Bidirectional: value → id, id → value |
| Durability tracking | `:atomics` array (one slot per level) | Lock-free reads during validation |
| Entity tables | ETS `:set` per entity type | Keyed by entity ID, per-field changed_at |
| Query registry | ETS `:set` | Query definitions, keyed by name |

All ETS tables are owned by `Roux.Database.TableOwner`. A dedicated `Roux.Database.Heir` process preserves tables across TableOwner crashes — see [D12](decisions.md). Query tasks read/write to ETS but never own the tables.

## Process model

```
Database.Supervisor (:rest_for_one)
├── Roux.Database.Heir        — receives ETS tables on TableOwner crash
├── Roux.Database.TableOwner  — owns all ETS tables during normal operation
└── DynamicSupervisor          — supervises query Tasks
    ├── Task (query A)
    ├── Task (query B)
    └── ...
```

**Table ownership**: Heir starts first. TableOwner creates all ETS tables with `heir: heir_pid`. If TableOwner crashes, tables transfer to Heir via `ETS-TRANSFER`. The supervisor restarts TableOwner, which reclaims tables from Heir. Table IDs (tids) are stable across transfers, so all existing `Database` structs remain valid.

**Query execution**: Each invocation of a derived query spawns a Task that:

1. Checks the memo table for a cached result
2. If stale or missing, executes the query function
3. Buffers all writes (memo entry, dependencies, entities) in process-local state
4. Flushes to ETS atomically on successful completion
5. On cancellation (task killed), no partial state leaks

An ETS-based dedup table prevents duplicate computation: before spawning, `ets.insert_new({query, key}, :computing)` — if it fails, another task is already computing, so the caller waits for that result.

## Key invariants

1. **Memo entries are never partial.** All writes are buffered and flushed atomically.
2. **Dependency lists are never stale.** When a query re-executes, the new dependency list replaces the old one atomically.
3. **Source positions never participate in early cutoff comparison.** This is enforced by the equality strategy, not by convention.
4. **The revision counter is monotonically increasing.** It never decreases, even across cancellations.
5. **Interned values use integer IDs, never atoms.** The BEAM atom table is not garbage collected.

## Compatibility notes

- **Pentiment**: Roux's span handling should be compatible with pentiment's absolute position model. Consumers use pentiment for diagnostic formatting; roux ensures spans are excluded from early cutoff comparison.
- **Quail**: E-graph optimization integrates as a normal derived query. Quail's pure/immutable database is a query result value stored in memo entries.

## Compilation output targets

Languages built on Roux.Lang can target any format that produces loadable BEAM modules:

| Target | Mechanism |
|--------|-----------|
| Elixir AST | `Code.compile_quoted/2` |
| Erlang abstract format | `:compile.forms/2` |
| Core Erlang | `:compile.forms/2` with `:from_core` |
| Raw BEAM bytecode | Direct chunk assembly |
