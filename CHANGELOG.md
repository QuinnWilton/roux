# Changelog

## Unreleased

### Changed (performance)

- **Validation no longer copies the values it is not looking at.** It asks
  each entry three things — has it been verified this revision, how durable
  is it, what does it depend on — and every one of them came from
  `Memo.get/2`, which materializes the whole `%Entry{}` including the
  memoized value.

  That is not the cheap read it looks like. ETS copies terms out on read;
  a large binary is refcounted and escapes with a pointer copy, but a
  memoized *structure* does not. Fact rows — lists of lists of short
  binaries — are deep-copied in full, and validation touches every
  dependency of every node.

  Measured at **747×** the cost of reading the fields directly (300 deps of
  800 fact rows each: 347 ms vs 0.47 ms). `Memo.dep_state/2`,
  `verification_state/2` and `dependencies/2` read the fields they need via
  `:ets.lookup_element/4` instead.

  End to end on planchette over credo (256 files):

  | | before | after |
  |---|---|---|
  | comment edit → analyze | 2693 ms | **122 ms** |
  | comment edit → supervision tree | 487 ms | **15 ms** |
  | body edit → analyze | 2656 ms | **106 ms** |
  | body edit → supervision tree | 499 ms | **2.9 ms** |
  | semantic edit → analyze | 4747 ms | **1404 ms** |

  Nothing about *what* validation decides changes; the new accessors are
  tested to agree with `get/2` exactly. Cold builds are unaffected, since
  they execute rather than validate.


### Fixed (correctness)

- **A duplicate requester now waits for the claimant to FINISH, not to
  die.** `Roux.Runtime`'s dedup slot let one process compute a key while
  others waited — but the only wakeup was a monitor `:DOWN`. That is
  indistinguishable from completion when the computing process is a
  short-lived `Task`, which is what every test used and what the original
  design assumed. It is a permanent hang when the computing process is
  long-lived: a GenServer, an LSP loop, an IEx session. Planchette hit this
  and had to serialise its query fan-out to work around it.

  The claimant now publishes completion to a `dedup_waiters` bag. The
  ordering is what makes it race-free: a waiter registers itself and *then*
  re-checks the claim row, while the claimant deletes the claim row and
  *then* reads the waiter list — so a row still present after registering
  means the claimant cannot have read the list yet, and a row already gone
  means the result is in the memo. The monitor is kept for the abnormal
  path, where no completion message is ever sent.

  Also fixes a related liveness bug: a claimant that died abnormally left
  its claim row behind (its `after` block never ran), so a woken waiter
  re-entered, failed `insert_new` against the dead claimant's row, monitored
  a dead pid, got an immediate `:noproc`, and looped — forever, because
  nothing else removed that row. A waiter now reaps a claim whose owner is
  gone, using `delete_object/2` so a claim since taken over by a live
  process is left alone.

  Note `release_dedup/2` uses `lookup` + `delete` rather than the atomic
  `take/2`: Concuerror does not model `ets:take`, and this is exactly the
  code its dedup scenarios exist to explore. The lost atomicity is safe —
  the completion message is the fast path, the waiter's re-check is the
  correctness guarantee. 326 of 326 interleavings explored clean.

- **`Roux.GC.sweep/1` no longer deletes the cache of any consumer that uses
  entities.** Entity-field dependencies are recorded in the same list as
  query and input dependencies but are not memo keys, so `Memo.get/2` on
  one always misses — and the orphan sweep read that miss as proof the
  entry was dead. The first `sweep/1` would have deleted every memo entry
  belonging to a query that reads an entity field, then cascaded to
  everything downstream. For lark or haruspex that is the entire cache.

  It never fired because nothing in `lib/` calls `sweep/1` and the existing
  orphan tests build their scenarios from input and query keys only. An
  entity-field dependency is now resolved against the entity table, which
  is where that liveness actually lives.


### Added

- **Per-key durability**, and the two soundness fixes it needs.
  `Roux.Input.set/5` takes `durability:` to override the input
  definition's level for one key — Salsa's
  `set_file_text_with_durability`, which lets a consumer mark the file
  being edited `:low` while its neighbours stay `:medium`, so a write
  advances only the low slot and validation can skip everything that
  cannot be affected. `Runtime` now reads a key's level from its own
  entry rather than from the input registry.

  Both failure modes below produce STALE VALUES with no error, and
  `test/roux/durability_test.exs` checks values rather than bookkeeping:

    * a key whose durability CHANGES now advances the revision at its OLD
      level. Readers recorded at that level check only it and above;
      advancing solely at the new, lower one left them skipping validation
      forever.
    * `Validation` now refreshes an entry's durability during the
      dependency walk. Durability is the minimum over transitive inputs
      and was only recomputed when an entry EXECUTED — but early cutoff
      means a dependent is usually validated WITHOUT executing, so it kept
      its first level indefinitely and then skipped a change at a lower
      one. The walk already reads every dependency's entry, so the current
      minimum is in hand exactly where it needs writing.
      `Memo.update_verified/4` writes both fields together.

  Worth knowing before reaching for this: measured on planchette, marking
  the edited buffer `:low` changed nothing — 57-60ms per keystroke with
  and without, on a 256-file project. Validation already short-circuits on
  `verified_at == current_rev`, which saves the same work. The technique
  is sound and available; it is not automatically a win.

- `Roux.Runtime.untracked/1` — runs a fun with dependency recording and
  durability propagation suppressed for the enclosing query, while nested
  queries still execute normally (memoized, deduplicated, cycle-checked in
  the same process). For demand-driven warm-up work whose exact
  dependencies are recorded separately, e.g. a compiler pre-loading hinted
  modules before compiling, with precise edges recorded from a tracer
  afterward.
- `Roux.Runtime.create/3`, `Roux.Runtime.field/4`, `Roux.Runtime.lookup/3` — entity helpers for use inside `defquery` blocks. `create/3` creates or updates an entity and records it in the output set for GC. `field/4` reads a field and records a field-level dependency for fine-grained invalidation. `lookup/3` performs a non-interning identity lookup without recording a dependency.
- `Roux.Runtime.read/3` — reads all fields from an entity as a map, recording a field-level dependency on each. Eliminates per-field reconstitution boilerplate.
- `Roux.Runtime.query!/3` — like `query/3` but throws on `{:error, reason}`, enabling flat error propagation instead of nested `case` statements. The throw is caught automatically by `defquery`-generated functions.
- `Roux.Runtime.input!/3` — like `input/3` but throws when the input key is not set, enabling flat error propagation matching `query!/3`.
- `Roux.Input.fetch/3` — non-raising variant that returns `{:ok, value}` or `:error`, matching the standard `Map.fetch/2` pattern.
- `defentity` macro — declares entity types alongside `defquery`/`definput` for automatic registration via `Roux.Lang.register_module/2`.
- `defquery` `:returns` option — generates a `@spec` for the query function, making return types visible in documentation and dialyzer.
- `Roux.Validation` — entity field dependency support. Dependencies of the form `{:entity_field, module, entity_id, field_name}` are validated by checking `Entity.field_changed_at/4` directly, enabling field-level early cutoff.
- `Roux.Lang` — optional `line_comments/0` and `language_name/0` callbacks for editor integration, with public accessor functions that provide sensible defaults.
- `Mix.Tasks.Roux.Gen.Zed` — generates a Zed editor extension (extension.toml, per-language config.toml, extension.wasm) from `Roux.Lang` module metadata.
- Pre-built `extension.wasm` shipped in `priv/editors/zed/` so consumers don't need a Rust toolchain.

### Changed

- `Roux.Revision.last_changed_at_or_below/2` renamed to `last_changed_at_or_above/2` — the old name contradicted the semantics (`:low` includes higher durability levels, not lower).
- `Roux.GC.sweep_query/4` changed to `sweep_query/3` with keyword options `old:` and `new:` instead of positional parameters, preventing silent argument swap bugs.
- `Roux.Database.register_query/3` is now idempotent — re-registering the same name overwrites the previous definition instead of raising `ArgumentError`, matching the behavior of `register_entity/2` and `register_input/2`.
- `Roux.Lang.Compiler` — prints "Compiling N files (.ext)" grouped by extension before compilation, matching the output style of Elixir's built-in mix compiler. Supports `verbose: true` option to print a message on noop builds.
- `Roux.Lang.register_module/2` — automatically registers entity types declared with `defentity`, eliminating manual `Database.register_entity/2` calls.
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
