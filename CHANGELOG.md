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
