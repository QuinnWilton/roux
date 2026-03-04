# Changelog

## Unreleased

### Added

- `Roux.Intern` — bidirectional value-to-integer-ID interning with lock-free concurrent insertion via atomics and ETS insert_new CAS pattern.
- `Roux.Revision` — global revision counter and per-durability-level change tracking via lock-free atomics. Supports durability optimization for skipping validation of stable subgraphs.
- `Roux.Telemetry` — structured `:telemetry` event definitions for all framework operations with typed helper functions enforcing consistent event shapes.
- `Roux.Database` — central handle struct with ETS lifecycle management, crash recovery via Heir/TableOwner protocol, and registration APIs for queries, inputs, entities, and intern tables.
- `Roux.Memo` — memo entry storage with atomic partial updates via `select_replace`, flat ETS tuple layout, and `entries/1` returning key-entry pairs for GC support.
- `Roux.Input` — external input values forming dependency graph leaves, with hash-based early cutoff to suppress redundant revision advances, and per-input durability levels.
- `Roux.Query` — derived query definition via `defquery` macro with `Roux.Runtime.execute/4` wrapping, `definput` for bulk input declaration, and `__before_compile__` metadata generation for module registration.
- `Roux.Entity` — tracked structs with identity that persists across revisions. Fields are individually tracked for changes via hash pre-check (D8), enabling field-level invalidation. ETS rows carry a reference count from day one (D15) for future GC integration.
- `Roux.Validation` — validation algorithm determining whether cached memo entries are still valid by recursively checking dependencies. Integrates durability-based skip optimization and early cutoff. Accepts an `ensure_fn` callback to break the compile-time dependency cycle with Runtime (D13).
- `Roux.Runtime.Context` — threaded context struct for query execution state: active query stack, recorded dependencies, created entities, and minimum durability tracking.
- `Roux.Cycle` — runtime cycle detection in the query dependency graph. Checks the active query stack and raises `Roux.Cycle.Error` with the full cycle path. Data structures support future fixed-point iteration (D7).
- `Roux.Runtime` — query execution engine integrating memoization, validation, cycle detection, early cutoff, write buffering, and dedup. Process-dictionary context threading for dependency tracking. Provides `execute/4` (main entry), `query/3` (nested dispatch), `input/3` (input reads), and `parallel/2` (fan-out with dep merging). Implements D13 `ensure_up_to_date` callback for Validation.
- `Roux.Cancellation` — process-based cancellation of in-flight query tasks via `Process.exit(pid, :kill)`. Forward-walks active tasks to find transitive dependents of changed inputs (Option A). Provides `register_task/3`, `unregister_task/2`, `cancel_dependents/2`, `cancel_all/1`, and `await_or_cancel/3` with noproc race handling.
