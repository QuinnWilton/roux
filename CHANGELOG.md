# Changelog

## Unreleased

### Added

- `Roux.Runtime.create/3`, `Roux.Runtime.field/4`, `Roux.Runtime.lookup/3` — entity helpers for use inside `defquery` blocks. `create/3` creates or updates an entity and records it in the output set for GC. `field/4` reads a field and records a field-level dependency for fine-grained invalidation. `lookup/3` performs a non-interning identity lookup without recording a dependency.
- `Roux.Validation` — entity field dependency support. Dependencies of the form `{:entity_field, module, entity_id, field_name}` are validated by checking `Entity.field_changed_at/4` directly, enabling field-level early cutoff.
- `Roux.Lang` — optional `line_comments/0` and `language_name/0` callbacks for editor integration, with public accessor functions that provide sensible defaults.
- `Mix.Tasks.Roux.Gen.Zed` — generates a Zed editor extension (extension.toml, per-language config.toml, extension.wasm) from `Roux.Lang` module metadata.
- Pre-built `extension.wasm` shipped in `priv/editors/zed/` so consumers don't need a Rust toolchain.

### Changed

- `Roux.Lang.Compiler` — reads configuration from `Mix.Project.config()[:roux]` instead of application environment. Exposes `compile/1` for direct invocation with explicit config.
- `Mix.Tasks.Roux.Lsp` — reads language configuration from `Mix.Project.config()[:roux]` instead of application environment.

### Fixed

- `Roux.Lang.LSP` — `didClose` now cancels stale in-flight tasks and republishes diagnostics based on restored disk content, matching the `didOpen`/`didChange` pattern.
- `Roux.Lang.LSP` — `safe_dispatch` now logs the full stacktrace on query failure instead of just the exception message.
- `Roux.Lang.LSP` — diagnostic ranges now support end positions via optional `:end_line`/`:end_column` fields, enabling editors to underline error spans.
- `Roux.Lang.LSP` — `didChange` gracefully handles empty `contentChanges` lists instead of crashing.
- `Roux.Lang.LSP` — definition handler now converts language results to LSP `Location` structs via `to_lsp_location/1`.

### Changed

- Extracted `dispatch_query/3` from `Roux.Lang.LSP` and `Roux.Lang.Compiler` into `Roux.Database.dispatch_query/3`, eliminating code duplication.

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
- `Roux.GC` — garbage collection of stale memo entries and dead entities. Provides `sweep/1` (periodic cleanup of zero-refcount entities and orphaned memo entries with cascade to fixed-point), `sweep_query/4` (output entity refcount diffing after query re-execution), and `mark_input_removed/3` (input deletion with revision advance).
- `Roux.Lang` — thin convention layer defining what it means to be a "language" in the Roux ecosystem. Behaviour with callbacks for file extensions, query registration, and compilation entry points. Provides `register/2` for language registration with extension conflict detection, `register_module/2` for bulk query/input registration, `lang_for_extension/2` for extension lookup, `resolve_interface/2` for cross-language module interface dispatch, and `registered_languages/1` for listing all registered languages. Optional IDE support callbacks for diagnostics, completions, hover, and go-to-definition.
- `Roux.Lang.Compiler` — Mix compiler integration that discovers source files by extension, updates inputs, dispatches compile queries, and returns diagnostics. Supports warm starts via manifest for incremental batch compilation without a long-lived VM.
- `Roux.Lang.Manifest` — manifest read/write for cross-VM incremental compilation. Serializes memo entries (excluding `:low` durability), entity tables, intern tables, and revision state to disk. Validates manifest version on load for graceful migration.
- `Mix.Tasks.Compile.Roux` — thin Mix compiler shim that delegates to `Roux.Lang.Compiler`.
- `Roux.Lang.LSP` — generic GenLSP-based language server that delegates IDE features (diagnostics, hover, completions, go-to-definition) to query-based language implementations. Shares memoized intermediate results with compilation via the same database. Full-text sync with debounced diagnostic push and cancellation of stale in-flight tasks. Position conversion between LSP 0-based and Roux 1-based coordinates.
- `Mix.Tasks.Roux.Lsp` — starts the Roux LSP server over stdio, reading language configuration from the `:roux` application environment.
- `Roux.Revision.snapshot/1` and `Roux.Revision.restore/2` — capture and restore atomics state for manifest persistence.
- `Roux.Intern.snapshot/1` and `Roux.Intern.restore/2` — capture and restore ETS tables and counter for manifest persistence.
