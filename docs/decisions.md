# Design decisions

Key architectural decisions and their rationale. Referenced from subsystem docs.

## D1: Threaded context over process dictionary

**Decision**: Use an explicit `db` parameter threaded through all query calls.

**Rationale**: Testability (inject isolated databases), support for multiple concurrent databases, compiler catches missing context. The ergonomic cost is one extra parameter, which `defquery` hides.

**Trade-off**: Every helper function that transitively calls a query needs the context parameter.

## D2: ETS from the start

**Decision**: Use ETS-backed storage from day one, not process-local maps.

**Rationale**: Avoids a storage layer rewrite between phases. ETS provides the concurrency primitives (read_concurrency, insert_new for CAS) needed for the concurrent task model.

## D3: Task per invocation (not GenServer per query)

**Decision**: Query computations spawn ephemeral Tasks, not long-lived GenServers.

**Rationale**: Tasks over different keys are independent and should run in parallel. A GenServer per query definition serializes independent work. Tasks provide clean cancellation (Task.shutdown). An ETS dedup table prevents duplicate computation without serialization.

## D4: Struct-based database identity

**Decision**: The database is a struct holding ETS table references, not a global singleton.

**Rationale**: Multiple independent databases in the same VM (testing, multiple LSP servers). Testing is dramatically easier with isolated databases. The `db` parameter is already threaded through everything.

## D5: Behaviour-based entity metadata (not protocols)

**Decision**: Entity schema metadata via module functions (`__entity__/1`), not protocol dispatch.

**Rationale**: Protocol dispatch overhead is significant on hot paths (entity creation, field access, identity matching). Direct module function calls are a single code server lookup. This is the pattern Ecto uses for schemas.

## D6: Durability from the start

**Decision**: Durability levels (high/medium/low) are built into the data model from day one.

**Rationale**: Retrofitting durability requires touching every subsystem. Salsa added it late and required significant rework. Even if the optimization logic is simple initially, the data model must carry durability information.

## D7: Cycle detection with abort (fixed-point designed for)

**Decision**: Cycles are detected and abort with an error. Fixed-point iteration is not implemented but the data structures support it.

**Rationale**: Fixed-point iteration is complex and only needed for specific language features (recursive types, dataflow analysis). Detecting cycles is required from day one to prevent deadlocks. The active query stack in the context supports future fixed-point iteration without structural changes.

## D8: Hash-based equality pre-check

**Decision**: Store a hash alongside memo values. Compare hashes before structural comparison.

**Rationale**: BEAM structural equality on large terms is O(n). Hash comparison is O(1). In the common "values differ" case, the hash catches it immediately. Full structural comparison only runs when hashes match (the "values are equal" case, which is when early cutoff fires).

## D9: Source positions excluded from early cutoff

**Decision**: Equality comparison for early cutoff ignores source position data. Enforced by the framework.

**Rationale**: Source positions are inherently volatile — inserting a newline changes every position below it. If positions participate in comparison, every edit invalidates the entire downstream graph, defeating the purpose of incremental computation. This is the most common mistake in incremental compiler design.

**Mechanism**: Query results implement a `Roux.Eq` protocol (or equivalent) that defines comparison semantics. The default implementation uses structural equality. Types containing source positions override it to exclude them.

## D10: Interned values use integer IDs, never atoms

**Decision**: User-facing strings (identifiers, paths, etc.) are interned to integer IDs.

**Rationale**: The BEAM atom table is not garbage collected and has a ~1M entry limit. A compiler processing large codebases could exhaust it. Integer IDs in ETS have no such limit and make equality comparison O(1).

## D12: Dedicated heir process for ETS crash recovery

**Decision**: Use a dedicated `Roux.Database.Heir` GenServer to preserve ETS tables across `TableOwner` crashes, rather than cold restart or using the supervisor as heir.

**Rationale**: ETS table IDs (tids) are stable across ownership transfers. When TableOwner crashes, tables transfer to Heir via `ETS-TRANSFER`. The supervisor restarts TableOwner, which reclaims tables from Heir via `:ets.give_away/3`. The tids never change, so every `Database` struct already handed out to callers remains valid — the crash is transparent.

Without the heir, a TableOwner crash destroys all tables. New tables get new tids, making every existing `Database` struct stale. This forces detection logic, error handling, and recovery paths throughout the codebase — far more complexity than the ~50 lines the heir costs.

**Supervisor strategy**: `:rest_for_one`. Heir starts first. If Heir crashes, TableOwner also restarts (tables are lost, cold restart). If TableOwner crashes, Heir stays up to preserve tables.

**Cost**: ~50 lines across `Roux.Database.Heir` (~25 lines) and changes to `TableOwner.init/1` (~15 lines) and supervisor setup (~10 lines).

## D13: Callback injection to break Runtime ↔ Validation cycle

**Decision**: Validation takes an `ensure_fn` callback that brings a dependency up-to-date. Runtime provides this callback. Validation never imports Runtime.

**Rationale**: Runtime and Validation are mutually dependent at runtime — Runtime calls Validation to check staleness, Validation needs stale dependencies re-executed before it can check their `changed_at`. This is a single recursive algorithm split across two modules.

Rather than merging them (losing the clean separation) or accepting a compile-time cycle, Validation accepts a callback: `validate(db, query_key, ensure_fn)`. The `ensure_fn` is `Runtime.ensure_up_to_date/2`, which itself calls `Validation.validate` recursively. The compile-time dependency is one-way: Runtime → Validation.

**Testability benefit**: Validation can be tested with fake `ensure_fn` callbacks — no need to wire up full query execution just to test validation logic. This makes it easy to test edge cases (deep chains, diamond deps, durability skips) in isolation.

## D15: Entity reference counting from the start

**Decision**: Entities carry a reference count tracking how many queries include them in their `output_entities` set. Built in from day one, not retrofitted.

**Rationale**: Same argument as durability (D6). Retrofitting refcounting means touching every code path that creates or removes entity references — query execution, re-execution, output set diffing, cancellation, `parallel/2` fan-out. Adding it later requires auditing all these paths.

Without refcounting, "is this entity alive?" requires scanning every memo entry's `output_entities` list — O(total memo entries) per entity. With refcounting, it's O(1): refcount > 0 means alive, 0 means dead.

**Cost**: One extra field in the entity ETS row. `:ets.update_counter/3` for atomic increment/decrement. ~20 lines in `sweep_query/4`, ~10 lines in the sweep.

## D14: Caller-owned concurrency with framework-provided fan-out

**Decision**: Top-level concurrency is the caller's responsibility (use `Task.async_stream` etc.). The framework provides `parallel/2` only for fan-out within query bodies where dependency merging is needed. `execute/4` is synchronous and concurrent-safe. `query/3` is inline.

**Rationale**: Requiring the user to opt into concurrency via a framework-specific `async/3` API is at odds with the BEAM's process-centric design. On the BEAM, the natural model is "spawn when you want concurrency" — the framework just needs to be safe under concurrent access, which it already is via ETS and the dedup table.

The only case where the framework must be involved is fan-out within a query body (`parallel/2`), because sub-query dependencies must be merged back into the parent context. Everything else is standard BEAM concurrency.

**Three contexts**:
- Top-level: caller spawns, framework deduplicates
- Nested `query/3`: always inline, same process
- Fan-out `parallel/3`: framework spawns, records the group as one dependency (D20)

## D16: Boundary enforcement via assert_boundary

**Decision**: Use `assert_boundary` to test that module dependencies conform to the architected subsystem dependency graph. The boundary test must be kept up to date as each subsystem is implemented.

**Rationale**: The subsystem dependency graph is a strict DAG — Validation must not depend on Runtime, Cycle must not depend on Runtime (only Runtime.Context), Tier 0 modules must have no Roux dependencies, etc. These constraints are load-bearing for testability and build order. A single misplaced `import` or function call silently breaks the architecture.

`assert_boundary` uses `:xref` to analyze actual call edges in compiled BEAM bytecode, so it catches real runtime dependencies — not just source-level aliases or imports.

**Enforcement**: A single `test/roux/boundary_test.exs` file uses `assert_boundary/2` for each subsystem, declaring its allowed dependencies as an allowlist. Any call to a module outside the allowlist fails the test. The boundary test runs in CI on every commit alongside unit tests.

**Subsystem dependency allowlist** (from subsystem docs):

| Module | Allowed Roux dependencies |
|--------|--------------------------|
| `Roux.Intern` | *(none)* |
| `Roux.Revision` | *(none)* |
| `Roux.Telemetry` | *(none)* |
| `Roux.Database` | Intern, Revision, Telemetry |
| `Roux.Memo` | Database |
| `Roux.Input` | Database, Revision, Memo, Telemetry |
| `Roux.Query` | Database |
| `Roux.Entity` | Database, Intern |
| `Roux.Validation` | Database, Memo, Revision, Telemetry |
| `Roux.Cycle` | Runtime.Context |
| `Roux.Runtime` | Database, Memo, Input, Revision, Validation, Telemetry, Cycle, Runtime.Context, Cancellation, GC |
| `Roux.Cancellation` | Database, Memo, Telemetry |
| `Roux.GC` | Database, Memo, Entity, Revision, Telemetry |
| `Roux.Lang` | Database, Query, Input |
| `Roux.Lang.Compiler` | Lang, Database, Input, GC |
| `Roux.Lang.LSP` | Lang, Database, Input, Cancellation |

**Rule**: When implementing a new subsystem, add its `assert_boundary` assertion before writing any module code. The test should fail (no modules yet), then pass once the subsystem is implemented with correct dependencies.

## D17: One module per file

**Decision**: Every module gets its own file, located at the path matching its namespace. `Roux.Memo.Entry` lives at `lib/roux/memo/entry.ex`, not inside `lib/roux/memo.ex`.

**Rationale**: Predictability — given a module name, the file path is mechanically derivable (and vice versa). This removes the need to search for where a module is defined. It also prevents compilation ordering issues: when two modules share a file and one references the other's struct, Elixir may fail to compile because the struct's module isn't defined yet. Separate files let the compiler resolve dependencies naturally.

**Exception**: None. Even small modules like `defexception` types get their own file.

## D11: Concuerror for concurrency correctness

**Decision**: Use Concuerror for exhaustive interleaving exploration of focused concurrent scenarios. Use StreamData for randomized concurrent integration properties.

**Rationale**: Roux's correctness under concurrent access depends on ETS operations (CAS via `insert_new`, `select_replace`, concurrent reads/writes) behaving correctly under all scheduler interleavings. Testing with random delays finds some races but misses rare interleavings. Concuerror systematically explores all scheduling points — if a race exists, it finds it.

**Trade-off**: Concuerror's state space is exponential, so scenarios must be small (2–3 processes, minimal operations). It tests focused data structure races, not full-system behavior. StreamData concurrent properties cover larger-scale convergence.

**Layered approach**:
- Concuerror: "this ETS interaction is correct under ALL interleavings" (exhaustive, small scope)
- StreamData concurrent: "this system converges under RANDOM interleavings" (probabilistic, large scope)
- ExUnit: "this behavior is correct under SERIAL execution" (deterministic, full scope)

## D18: Code versions are inferred from the code, and checked before the durability skip

**Decision**: Each memo entry stores the code version of the query that computed it. `use Roux.Query, code: opts` derives a module's versions from the import-closure digest of its beams (`Roux.Code`); `defquery`'s `code:` adds roots reached by dynamic dispatch and `version:` a hand-bumped term. Validation treats an entry of another version as stale, and checks it *before* the durability skip. A restore that finds any restored entry of another version advances the revision once at `:high`.

**Rationale**: A memoized value is a function of its reads and of the code that computed it; without the code, a tool upgraded in place serves results its old code computed. Declared versions rot, so the version is read off the beams: an edit to a module moves exactly the versions whose closure reaches it. The check precedes the durability skip because no input moved — the skip would pass the entry. Restoring advances at `:high` because a dependent of a changed query would otherwise skip its dependency walk and never see its dependency re-executed. Early cutoff is unchanged, so an edit that changes no result recomputes nothing downstream.

**Trade-off**: A closure covers what the import table and the literal table's external funs show; `apply/3` and calls through a module in a variable must be declared as roots, and `Roux.Code.Verify.executed/2` exists so a consumer can test that nothing it runs lies outside. Closures stop at OTP and Elixir (their versions are in the digest) and at consolidated protocols.

## D19: Persistence is a query's policy; a transient value takes its readers with it

**Decision**: `defquery`'s `store: :inline | :blob | :none` says how a manifest keeps a query's entries, and `transient: predicate` marks values that are never kept — nor is any entry that read one, transitively, computed at manifest write.

**Rationale**: A consumer needs to keep a failure out of the manifest so the next run retries it. Dropping the failing entry alone is not enough: its readers, restored, pass their durability check (no input moved) and serve what the failure led to forever. The cascade is the only sound form.

## D20: A fan-out is one dependency, validated concurrently, by lean workers

**Decision**: `Runtime.parallel/3` records one dependency `{:parallel, max_concurrency, keys}`. Validation hands it to `ensure_fn`, which brings every member up to date concurrently, then checks each member's `changed_at`. Workers are `spawn_opt`'d with a link and a monitor; each unlinks itself before exiting normally; exceptions are caught and re-raised in the caller.

**Rationale**: With one dependency per member, a warm validation brings members up to date one by one — a program merging hundreds of modules re-executes its stale ones in turn. Grouping lets validation fan out as execution did. `Task.async_stream` was the first choice, but its monitor process and bookkeeping put hundreds of scheduling points into each fan-out, beyond what Concuerror can explore; and linked tasks send `:EXIT` messages to a caller that traps exits (an LSP server). Unlinking before a normal exit avoids both; the monitor still reports a worker killed from outside.

**Trade-off**: GC, cancellation and the manifest's transient cascade must read a group as its members. Two of the three Concuerror scenarios are bounded (four and two preemptions): the unbounded state spaces are beyond a CI job.

## D21: A content-addressed blob store with immutable entries and a grace-period collector

**Decision**: `Roux.Blob` keeps entries under the SHA-256 of their bytes, installed by rename from a staging name and read-only on disk; an action cache and verifying traces keep terms under keys. A lookup touches without creating; a collection marks from the live roots (every owner's retained digests, and the digests named by recently used pointers) and sweeps the rest once older than a grace period, renaming each aside first and putting it back if it was touched meanwhile.

**Rationale**: Large values (fact files, solver outputs, findings) are shared across processes and worktrees and must survive a concurrent collector. Rename is the one atomic step a file system offers, so a reader finds an entry whole or not at all; immutability makes two writers of one entry both right; a vanished or corrupt entry is a miss, never an error. Hard links, never symbolic ones, so a collected entry cannot dangle in a scratch directory. The grace period is what protects a run's entries between writing them and retaining them.

## D22: Values held by digest: digest cutoff, transparent recompute

**Decision**: With a blob store, a manifest keeps a `store: :blob` value in the store and holds its digest. The value is loaded by the first read that needs it. Early cutoff over such an entry compares the new value's digest with the held one, reading nothing (and putting the bytes back). A valid entry whose blob is gone is recomputed transparently and keeps its `changed_at`.

**Rationale**: A warm run reads few values; carrying them in the manifest costs load time and bytes. The digest is a complete stand-in for equality (deterministic encoding), and a missing blob only costs a recomputation. Each manifest retains what it names, so a collection keeps a live manifest's blobs.

## D23: An optional input depends on its absence

**Decision**: `Runtime.input(db, name, key, default: v)` records `{:input_absent, name, key}` when the key is unset. Validation keeps it clean while the key is unset and stale once it has a value. A key set for the first time advances the revision at the more durable of its own level and its input's.

**Rationale**: Guarding a read with `Input.exists?/3` either records no edge (the reader never learns the key was set) or an edge to a missing entry (stale on every validation). The absence edge is exact. The reader recorded the input's registered durability, having no key's; advancing at the lower per-key level alone would leave its durability check skipping the change.

## D24: A session writes its manifest only when the run changed it

**Decision**: `Roux.Session` registers queries, then restores (so restore can drop unregistered queries' entries), and `commit/3` writes only when the revision moved, an entry was written, or the sources' metadata changed. A small `extra` term is kept beside the manifest.

**Rationale**: A warm no-op run's budget is a fraction of a second; rewriting a multi-megabyte manifest it did not change is most of it. The `extra` sidecar lets a Mix compiler's `diagnostics/0` answer without loading the manifest.

**Restore and unregistered queries**: a restore leaves out every entry of a query that is not registered and every entry that read one, transitively, as the manifest's transient cascade does (D19). Treating such a dependency as stale at validation instead would still leave the dangling edge in the table, and a reader restored above it would pass its durability check without ever walking to it. Scanning the restored dependencies costs about 0.3 ms on a 3,354-entry manifest.

## D25: Telemetry events name their database

**Decision**: Every event about a database carries `database:` (`Roux.Database.id/1`, its memo table's tid), and `Roux.QueryLog` filters on it.

**Rationale**: Concurrent tests, or a compiler beside an LSP session, run several databases in one VM; a handler that cannot tell them apart counts others' work as its own. The memo table's tid is unique, stable across a table owner restart, and needs no new field.

## D26: gen_lsp is optional

**Decision**: `gen_lsp` is an optional dependency; `Roux.Lang.LSP` compiles only where it is installed.

**Rationale**: A tool that never serves LSP — an escript above all — should not bundle a JSON-RPC stack and its four dependencies. A project serving LSP through roux declares the dependency it uses.

## D27: The blob store's trust model is the manifest's; its boundary is ownership and permissions

**Decision**: `Roux.Blob` decodes CAS terms, action-cache values, traces and blob-held memo values without `:safe`, as the manifest decodes its own. `Roux.Blob.open/1` refuses a store root, or its `FORMAT` file, that the current OS user does not own or that is writable by its group or by everyone (`Roux.Blob.TrustError`); a symbolic root is followed and its target checked the same way, and a symbolic `FORMAT` is refused. A root `open/1` creates, and `temporary/0`'s, is made `0700`. Bytes that do not decode are still a miss.

**Rationale**: A store's files are written by this tool, for this user, on this machine: the same trust as a manifest in `_build`. `:safe` is for input from outside that boundary, and inside it only cost: a term naming an atom the VM has not made yet (a function name in a stored finding, a module in a line table) decoded as a miss in every fresh VM, so each new Mix run rebuilt what the store held. Two decode policies for one kind of file also meant two trust models. The flag was never the boundary; who can write the files is, so `open/1` checks that, once, where a store is chosen.

**Trade-off**: The check covers the root and `FORMAT`, not every file below them: a root writable by no one else keeps others out of what it holds (and one roux creates is `0700`, which keeps them from reading it too). On Windows, whose file modes say nothing of this, every root passes.
