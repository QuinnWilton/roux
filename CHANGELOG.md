# Changelog

## Unreleased

### Added

- `Roux.Intern` — bidirectional value-to-integer-ID interning with lock-free concurrent insertion via atomics and ETS insert_new CAS pattern.
- `Roux.Revision` — global revision counter and per-durability-level change tracking via lock-free atomics. Supports durability optimization for skipping validation of stable subgraphs.
