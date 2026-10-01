# Changelog

## Unreleased

### Added

- Queries can use `revalidate: :execute` to run a tracked cache check before
  walking their previous dependency graph. Clean hits and early cutoff remain.
- Reverse dependency tracking skips validation of unaffected queries in every
  database and session.
  It adds index memory and input-update work; restored entries validate once,
  and databases with entity types retain ordinary validation.
- `Roux.Runtime.query_code/2` tracks a query's code version without demanding
  its value, so cached aggregates can track computations they bypass.
- Packed trace groups batch small cache records into indexed blobs. Records
  remain independently verifiable and readable without a session manifest;
  garbage collection retains and removes whole packs.
- Query deadline scopes can wrap dependency validation as well as execution,
  allowing cache batches to include work triggered by validation.

- Query deadlines cover dependency validation, execution and missing-value
  recovery. Concurrent callers share one attempt; a timeout cancels its nested
  workers and can produce a transient fallback for retry in the next session.

### Fixed

- Verify memo generations for query keys containing maps, `_`, or `$`-prefixed
  atoms without invalid ETS match specifications.
- Entity fields use exact equality when checking for changes, so numerically
  equal values with different representations cannot leave stale field values.
- Queries preserve early cutoff across registered code changes: a query whose
  new code returns the same value does not force its readers to execute.

### Changed

- Reuse encoded live memo values across checkpoints and equal recomputations.
  Live reads continue using decoded values; encoding caches do not invalidate queries.
- Blob-valued memos share bounded storage packs, reducing checkpoint file
  operations. Reads verify individual records, unchanged values keep their
  locations, and sparse packs are compacted within a bounded budget.
- Reverse-edge insertion avoids duplicate scans for dependencies with many
  readers, reducing cold publication and session restoration work.
- New sessions restore memo entries and their reverse edges in batches before
  exposing the database. Restored values still validate on demand.
- Reexecuting an unchanged cache proof preserves healthy packed storage and
  does not trigger a checkpoint when its persisted metadata is unchanged.
- Concurrent requests share cold code-closure and digest computations. Code
  walks also cache the OTP root, avoiding repeated calls to the code server.
- Query definition format is now 2. Recompile query modules against this release.
- Manifests now use format 7 for packed value locations and query-code
  dependencies. Formats 5 and 6 remain readable; older Roux versions reject
  format 7 and rebuild.

- Validation skips recursive checks for input leaves and shared queries already
  checked in the current revision. Input changes and deletions still invalidate
  their readers, while graphs with many shared dependencies do less work.

## 0.2.3 — 2026-09-29

### Changed (performance)

- **A query records each dependency once**, in the order it first
  demanded it, however often it demands it (`Roux.Runtime.Context`'s
  `seen_deps`). An entry could hold the same read two or three times,
  and validation walked each copy. Real manifests held 1–2% repeats
  (realtime's scry manifest: 26,489 edges, 316 repeats, 0.1% of its
  26 MB; argus on aeromancy: 3,719 edges, 79 repeats, 0.4% smaller); a
  repeated edge cost about 0.45 µs of each walk.
- **A code digest the VM memoized is kept in every store it is served
  for.** `Roux.Code.digest/2` memoized per VM without regard to the
  store, so a VM that opened a second store (a peer's, another
  project's) left it empty, and a fresh VM there walked every closure
  again. The memo now keeps what the digest observed, and the first call
  with each store puts that trace there — once per store in a VM — so it
  verifies only where those observations still hold (D32). On an
  822-module closure a fresh VM reading the second store took 320–620 ms
  to walk it, and takes 31 ms to verify the trace; the first VM spends
  2 ms putting it.

### Added

- `Roux.Blob.Trace.find_trace/4`: the trace `find/4` returns the value
  of, observations and all.

### Fixed

- **Validation leaves an input's durability as it was set.** A walk that
  met an input as a dependency took it for a query of no dependencies
  and wrote the minimum over nothing, `:high`, over its level. Its
  readers then took `:high` too, and the next write at the input's own
  level advanced the revision at `:high` (`Roux.Input.set/5` advances
  at a key's old level), which no durability check skips: after the
  first edit, every edit at `:low` walked every entry. No value was
  stale.

## 0.2.2 — 2026-09-29

Five races in the blob store a Concuerror model found, each a spurious
miss under concurrent use — a lookup finding nothing, or a value's
blob, while it was there to find — and so work done again, or, for a
consumer that takes a named blob's absence as an error, an error. None
returned a value other than one that was put: the model checks every
lookup against the values written.

### Fixed

- **A trace written or used within the window is never pruned** (D34).
  A put kept a name's `keep:` most recently used traces by modification
  time, but a hit marks a trace only when it is older than the store's
  refresh interval, so a trace in use could be pruned by count; writers
  racing under one name pruned each other's new traces (three writers
  with `keep: 2` could leave one). A put now keeps every trace written
  or used within the store's window (`Roux.Blob.window/1`, twice the
  refresh interval), and `keep:` bounds only the older ones.
- **A trace given a new value is never missing while it is replaced**
  (D33). Its file was renamed over, and a replacing rename is not atomic
  everywhere (APFS): a lookup in its moment found no trace. Argus writes
  its one trace per module this way on every rebuild.
- **An action-cache entry remembered again is never missing while it is
  replaced** (D33): the same rename, under `recall/2`.
- **A trace a collection puts back keeps what it names** (D35). A
  collection marked from the traces it found used, swept the CAS, then
  swept the old traces, putting back one a lookup had marked used
  meanwhile — which then named a blob already swept, for good: every
  later lookup found the trace and missed the blob.
- **A trace put again unchanged is marked used** (D34), so a prune by
  another process keeps it: a second VM re-putting an old trace could
  see it pruned right after.

### Changed

- Elixir `~> 1.19` is now required (was `~> 1.18`); OTP 28 remains
  required. CI tests Elixir 1.19.4 only.
- Traces and action-cache entries are versions: `traces/<name
  digest>/<observations digest>.<time>.<bytes digest>`, each renamed into
  a name nothing else takes, and the action cache keeps each entry as a
  trace of no observations. Traces and entries in 0.2.1's layout are
  still read, and superseded by the next write. A put of a trace's
  newest bytes writes nothing (D33).
- `Roux.Blob.Trace.find/4` and `Roux.Blob.recall/2` miss a trace or
  entry that went between their read and their touch, rather than
  return a value a collection may be taking the blobs of; a lookup
  looks again for a version superseded as it read. New:
  `Roux.Blob.Trace.mark_used/1` (`:gone` for such a trace), for a
  caller that fetches traces itself.
- A collection sweeps the traces and action-cache entries unused for
  its keep period before it marks and sweeps the CAS, and its grace and
  keep periods are never shorter than the window (D35).

## 0.2.1 — 2026-09-27

### Fixed

- **A code digest kept in a store no longer verifies in another build**
  (D32). `Roux.Code.digest/2` with `store:` kept a digest as a trace over
  the stat stamps of the beams its walk read, and verified that those
  files were unchanged — not that a walk now would read them. Builds
  that share a store each leave their files in place: two checkouts or
  worktrees of a project, an application renamed with its old `ebin`
  still in `_build`, an escript beside a Mix project. A trace kept over
  one build's beams verified in the other and served the first build's
  digest as the second's code version, so every result keyed on it was
  reused across code it was not computed by. **0.2.0 can serve stale
  results**: argus, whose extracted facts are keyed on these digests,
  reused facts extracted by another build's extractors — after the
  `panoptes` → `argus_beam` rename, facts of an older schema that the
  new rules cannot parse, degrading analyses. A kept digest now also
  observes where every module the walk met resolves (`:code.which/1`,
  one observation of them all), and a module found in other files fails
  it. Traces 0.2.0 kept are never consulted (the trace name carries a
  format). Upgrade; and a store 0.2.0 wrote may hold results filed under
  another build's code version, so if analyses came out degraded, delete
  the store directory (for argus, `~/.cache/argus/store`, or
  `$ARGUS_CACHE_DIR`). A collection (`argus gc`) is not enough: it
  removes only what went unused, and stale results in use survive it.

## 0.2.0 — 2026-09-27

0.2 makes roux the whole incremental backend of a tool like argus: code
versions, a content-addressed blob store, persistence policies, fan-out
groups, and a session that ties them to a manifest.

### Added

- **Code versions** (`Roux.Code`, `Roux.Query`). `use Roux.Query, code:
  opts` versions every query of a module by the code its module reaches:
  the import-closure digest of its beams (`Roux.Code.digest/2`), stopping
  at OTP, Elixir and consolidated protocols, whose versions it carries
  instead. `defquery ..., code: roots | {m, f, a}` adds roots reached by
  dynamic dispatch; `version: term` mixes in a hand-bumped term. Each memo
  entry stores its query's code version; validation treats another
  version as stale (before the durability skip), and early cutoff still
  keeps `changed_at` when the value comes back the same.
  `Roux.Runtime.code_version/0` hands a body its own version.
- `Roux.Code`: `closure/2` (with `exclude:` and `follow_excluded:`),
  `digest/2` (memoized per VM; with `store:`, kept across VMs as a
  verifying trace over the beams' stat stamps), `beam_digest/2` (the
  chunks with the build root replaced, so two worktrees of one commit
  digest the same), `build_root/1`, `canonical_beam/1` (a beam without
  `ExCk` and `Docs`), `runtime_version/0`, `forget/0`, and
  `Roux.Code.Verify.executed/2` (the modules a computation called into,
  for a closure test). Object code is read with
  `:code.get_object_code/1`, which works inside escripts. In an escript
  that embeds Elixir, Elixir's modules are recognized by their
  application (its library directory is inside the archive, not beside
  the escript), and a module in the archive is stamped by the escript
  file: a fresh run verifies a kept digest with one `stat`.
- **`use Roux.Query, around: {m, f}`** runs every body of a module inside
  `m.f(%{db:, query:, key:}, body)`, within the query's execution: what
  the hook reads becomes the query's dependency.
- **Persistence policy**: `defquery ..., store: :inline | :blob | :none`
  and `transient: predicate`. A `:blob` value is kept in a `Roux.Blob`
  store by digest; a `:none` entry is never kept; a transient value — and
  every entry that read it, transitively — is not kept, so the next run
  asks again (a reader restored without it would pass its durability
  check forever). `Roux.Memo.Entry` gains `code_version`, `persist` and
  `blobs`.
- **Optional inputs**: `Roux.Runtime.input(db, name, key, default: v)`
  reads `v` for an unset key and records `{:input_absent, name, key}`:
  the reader stays fresh while the key is unset and goes stale when it is
  set.
- **`Roux.Runtime.parallel/3`** (`max_concurrency:`, `timeout:
  :infinity`): a fan-out is one dependency, `{:parallel, max, keys}`, and
  validation brings the members up to date concurrently. Members run in
  workers linked to the caller that carry its query stack; what one
  raises is raised again in the caller; a caller that traps exits gets no
  `:EXIT` messages.
- **`Roux.Blob`**, a content-addressed store safe across OS processes:
  `open/1`, `open!/1`, `temporary/0`, `destroy/1`; CAS `put/2`,
  `put_term/2`, `encode_term/1`, `put_encoded_term/3`, `adopt/2` (a file
  moved in by rename), `get/2`, `get_term/2` (decoded `:safe`), `fetch!/2`,
  `member?/2`, `link/3` (a hard link, never a symbolic one), `path/2`; the
  action cache `recall/2`, `remember/3`, `cached/3` (errors never kept);
  `Roux.Blob.Trace` (`put/4`, `fetch/2`, `find/3`: verifying traces);
  `scratch/2`; `retain/3` and `release/2` (roots); `gc/2` and
  `maybe_gc/2` (mark from the live roots and recently used pointers,
  sweep the rest after a grace period, renaming aside first). Entries are
  immutable and installed by rename; a vanished or corrupt entry is a
  miss. `Roux.Blob.MissingError`, `Roux.Blob.FormatError`.
- **A CAS entry is never replaced** (D30): `Roux.Blob.put/2` and
  `adopt/2` hard-link an entry into place, a name already there being
  the same bytes, where they renamed over it. On APFS a replacing rename
  leaves the name missing for a moment, and a concurrent `link/3` of the
  empty relation entry every solve links failed with `{:error, :enoent}`
  (on three OS processes over 1.5 s: 633 of 2,192 links before, none of
  2,699 after). A collection's aside copy is named after the entry's
  digest and `link/3`/`get/2` use it while the name is missing; action
  cache entries, traces and roots are replaced only when their bytes
  change; a collection that cannot read a root sweeps nothing; scratch
  directories are made exclusively under a name with a per-VM token;
  manifest and sidecar reads retry an `ENOENT` twice. Concuerror scenarios
  over a model file system (`Roux.Test.ModelFS`) cover each.
- **The store's file I/O is raw, and a hit refreshes an entry at most
  once an hour** (D29): `Roux.Blob`, `Roux.Blob.Trace`, `Roux.Stamp` and
  `Roux.Code`'s stamps no longer go through the VM's file server, which
  serialized every lookup of a `Roux.Runtime.parallel/3` fan-out (1,000
  warm lookups on 8 workers: about 400 ms before, 140 ms after). A hit
  sets an entry's modification time only when it is older than the
  store's `refresh:` interval (`Roux.Blob.open/2`, an hour by default), so
  a warm run writes nothing; `gc/2` never uses a grace or keep period
  shorter than it. Traces carry their `mtime`.
- **A trace name's history is bounded** (D28): `Roux.Blob.Trace.put/5`
  keeps the `keep:` most recently used traces of the name (default 8,
  or `:infinity`) and removes the rest, rename-aside then unlink; a hit
  through `find/4` touches its trace. `Roux.Blob.Trace.fetch/3` and
  `find/4` take `limit:` and read and decode only the most recently used
  `limit` traces (default: all).
- **The blob store is trusted as the manifest is** (D27): its terms decode
  without `:safe`, so a term naming an atom a fresh VM has not made yet
  is a hit, not a miss. `Roux.Blob.open/1` enforces the boundary instead:
  it refuses a root or `FORMAT` that another user owns or that its group
  or everyone can write (`Roux.Blob.TrustError`, naming the path and the
  `chmod`/`chown` to fix it; `open/1` returns it, `open!/1` raises it),
  follows a symbolic root to check its target, and makes the roots it
  creates `0700`.
- **`Roux.Session`**: `open/1` (`modules:`, `languages:`, `manifest:`,
  `blob:`, `force:`), `commit/3` (writes the manifest iff the run changed
  something it holds; `extra:` keeps a small term beside it), `read_extra/1`,
  `files/1`, `close/1`.
- **`Roux.Sources.sync/5`**: an input keyed by file brought up to date
  with the disk — the stat prefilter, a guard for files written within
  `recent:` seconds, hashing, and removal of vanished keys.
- **`Roux.Stamp.memo/4`**: a value kept while its files' stat stamps
  hold, per VM and in a blob store's action cache.
- **`Roux.QueryLog`**: a telemetry collector of one database's (or every
  database's) executions, hits and cutoffs: `start/1`, `executions/2`,
  `hits/2`, `cutoffs/2`, `by_query/2`, `reset/1`, `stop/1`.
- `Roux.Runtime.hold/1`: the blob digests a body's value names, kept
  alive by the manifest that keeps the entry.
- `Roux.Database.new/1` takes `blob:`; `Roux.Database.id/1`,
  `writes/1`, `input_durability/2`, `code_version/2`, `query_definition/2`,
  `query_registered?/2`.
- `Roux.Memo.fetch_value/2`, `held_digest/2`, `code_version/2`,
  `reduce_dependencies/3`, `keys_persisted_as/2`, `persisted?/1`.
- `Roux.Lang.Manifest.write/4` (`blob:`) and `memo_entries/2`.
- `[:roux, :blob, :missing]` telemetry: a value held by digest was gone,
  and is recomputed.
- `mix concuerror`: a module's `concuerror_options/0` may set
  `depth_bound:`, `dpor:` and `scheduling_bound:`.

### Changed (breaking)

- **A module of queries carries a definition format, and registration
  reads only its own** (D31). `use Roux.Query` stamps `__roux_format__/0`
  (`Roux.Query.format/0`, `check_format/1`); `Roux.Lang.register_module/2`
  raises `Roux.Query.FormatError` for a module compiled against a roux of
  another format — including every module compiled against 0.1, which
  has none — where it raised `KeyError` reading the fields 0.1's
  definitions lack, and `ArgumentError` for a module that is not
  available or does not use `Roux.Query`. `Roux.Session.open/1` shuts
  its database down when a registration raises.
- **The Roux Mix compiler waits for `:elixir` when its languages are not
  ready** (D31). A language not compiled yet (a cold build) or compiled
  against another roux (an upgrade, whose warm build failed with
  `KeyError` until `mix clean`) is run once `:elixir` has compiled it,
  when `:elixir` follows `:roux` in the project's compilers
  (`Mix.Task.Compiler.after_compiler/2`): a cold build compiles its
  sources in its first run, where it compiled them only in the next. A
  language still not ready then is an error diagnostic.
- **`gen_lsp` is an optional dependency.** `Roux.Lang.LSP` compiles only
  where it is installed; a project serving LSP through roux adds
  `{:gen_lsp, "~> 0.11.3"}` itself. `mix roux.lsp` without it raises
  naming the dependency.
- **Telemetry events carry `database:`** (`Roux.Database.id/1`), every
  event but `[:roux, :intern, :new]`; the `Roux.Telemetry` event helpers
  take the database as a new first argument.
- **Manifest format 5**: each entry carries its code version and the
  blob digests it holds, and a `store: :blob` value may be held by
  digest. Manifests of any other format — including the unreleased
  format 4 — are discarded and rebuilt once. `Roux.Memo.persisted()`
  tuples have ten elements.
- **`Roux.Lang.Manifest.restore/2` leaves out the entries of queries that
  are not registered, and every entry that read one, transitively**:
  register a database's queries before restoring (`Roux.Session.open/1`
  does). A kept reader would hold an edge nothing can re-execute — the
  next validation that walked it raised `ArgumentError` — and its own
  readers' durability checks would pass over it. A restored entry of
  another code version is kept, stale, and the revision advances once at
  `:high`.
- **The memo table's ETS rows have twelve elements** (0.1.4 had eight):
  the encoding (or `{:blob, digest}`), the code version, the persistence
  policy and the held blobs. `Roux.Input.keys/2` matches them; code that
  matches the table directly must too.
- **`Roux.Runtime.parallel/2` records one group dependency** where it
  recorded one per member, has no 5-second timeout, and re-raises a
  member's exception in the caller (a member used to crash its caller
  through the link).
- `Roux.Memo.get/2` misses an entry whose value's blob is gone.
- `Roux.Input.set/5` of a key set for the first time advances the
  revision at the more durable of the key's level and its input's, so a
  reader of the key's absence sees it.
- `Roux.Database.register_query/3` advances the revision at `:high` when
  a query is registered again under another code version.
- `Roux.Database.new/1` validates its options (it ignored them).
- The Roux Mix compiler (`Roux.Lang.Compiler`) runs on a `Roux.Session`
  and `Roux.Sources`: a file touched without an edit is read and
  compiles nothing — the run is `{:noop, []}`, where it recompiled every
  file — and the manifest's `sources` hold `Roux.Sources` metadata.
- `Roux.Memo.persisted/2` also takes a three-argument filter, which sees
  the entry's persistence policy, and a third `hold` argument.

### Changed (performance)

- GC's orphan sweep and cancellation's dependency walk read dependency
  lists without copying values out of ETS.

- **Manifests restore lazily and write only what changed** (manifest
  format 4, since superseded by 5; manifests of any earlier format are
  discarded and rebuilt once — no release carried format 3 below). Restoring a manifest decoded
  every memoized value and copied it into ETS, and rebuilt every intern
  table, though a warm run validates entries by their metadata and reads
  the values of a handful. Each value is now its own binary inside the
  payload (level-1 compressed, as before): `Roux.Lang.Manifest.restore/2`
  inserts entries with their values still encoded, the first read that
  needs a value decodes it, and an intern table loads on its first miss.
  Writing reuses those encodings for every value that was not replaced —
  and for every value re-execution found unchanged, see below — and an
  intern table nothing was interned into hands back its restored rows; the
  encoding runs in a process of its own, so its garbage does not trigger
  collections of the caller's heap. On a 350-module scry project (realtime)
  loading and restoring the 25 MB manifest takes 13 ms instead of 320, a
  warm `mix compile` spends 0.40 s in scry instead of 0.78, and a
  one-module edit 2.9 s instead of 3.9 (the manifest write in it: 0.3 s
  instead of 0.9). The manifest grows from 17 to 25 MB: the intern rows are
  no longer compressed, as decoding them compressed on first use cost more
  than reading the extra bytes.
- **Manifests are checksummed and written atomically.** A format-4
  manifest is a header (`ROUXMNFT`, the format number, a CRC-32 of the
  payload) and the payload; `Roux.Lang.Manifest.load/1` refuses a
  manifest whose checksum or shape does not hold, so a truncated or
  corrupted file is rebuilt from scratch, never partly read — which lazy
  decoding requires, as a value is decoded long after the load. `write/3`
  writes a temporary file beside the manifest and renames it over the old
  one, so an interrupted write leaves the previous manifest in place.
- **A re-execution that comes back unchanged keeps the stored value.** A
  stale entry's value was copied out of ETS before its query re-ran, only
  to be compared with the new one, and the equal new value was then
  copied back in. `Roux.Runtime` now reads the replaced entry's hash,
  `changed_at` and output entities (`Roux.Memo.prior_state/2`, under the
  key's dedup claim, where no other computation can replace the entry),
  reads the stored value only when the hashes agree, and on early cutoff
  rewrites everything but the value (`Roux.Memo.put_unchanged/3`). Reading
  the prior state under the claim also means a re-execution compares
  against the entry it actually replaces, where it used to compare against
  the one it saw before claiming.

### Added (lazy manifests)

- `Roux.Memo.persisted/2`, `restore_persisted/2` and `decode_persisted/1`:
  entries in the form a manifest carries them, with each value in the
  external term format. A restored entry's value stays encoded until
  `get/2`, `entries/1` or `reduce_entries/3` returns it; the value-free
  accessors never decode it.
- `Roux.Memo.prior_state/2` and `Roux.Memo.put_unchanged/3` (see above).
- `Roux.Intern.encode_snapshot/1` (`%{version: 3, forward: binary, counter:
  n}`), which `Roux.Intern.restore/2` now also accepts, leaving the rows
  pending until the table is first used.

### Changed (lazy manifests)

- The memo table's ETS rows gained a ninth element: the value's encoding
  for an entry restored from a manifest, `nil` otherwise (the value
  position is then `nil`); now twelve, see above.
- `Roux.Lang.Manifest.manifest_data`'s `memo_entries` are
  `Roux.Memo.persisted()` tuples and its `intern_data` holds encoded
  snapshots; `Roux.Lang.Manifest.memo_entries/1` still decodes them.

- **Intern tables persist in one direction** (manifest format 3; older
  manifests are discarded and rebuilt once). `Roux.Intern.snapshot/1`
  stored both the forward and the reverse table, so every interned value
  was written twice — 29 MB of a 75 MB scry manifest on an 859-module
  project. Snapshots now carry the forward table (the authoritative one:
  it never holds the orphaned ID of a lost insert race) plus the counter,
  tagged `version: 2`; `Roux.Intern.restore/2` rebuilds the reverse table
  and raises `ArgumentError` for any other format. On that project the
  manifest shrinks from 75 MB to 61 MB and restoring it takes 1.7 s
  instead of 2.0 s.

## 0.1.4 — 2026-09-16

### Changed

- Depends on `gen_lsp` from Hex (`~> 0.11.3`) instead of a fork, so roux
  can be published. The fork existed for the test runner: the buffer's
  reader calls `System.stop/0` when the client socket closes, which under
  ExUnit happens on every test's cleanup and took the VM down mid-run.
  Upstream exposes that as the `:exit_on_end` application setting; the
  test config sets it to `false`. The fork's other change — the TCP
  reader crashing instead of reporting `:eof` when the socket closes
  mid-message — stays staged for upstream; nothing in roux's suite
  reaches it once the VM keeps running.

## 0.1.3 — 2026-09-16

### Changed (performance)

- **Manifests serialize memo entries one at a time** (format 2; older
  manifests are discarded and rebuilt once). Writing dumped the whole
  memo table into one term — a second heap copy of everything the
  database held — and compressed hundreds of megabytes in one call; on a
  600-module project that was 17 s and the peak of the run's memory.
  Entries now cross the heap singly in both directions and compress at
  level 1. `Roux.Memo.reduce_entries/3` folds over the table without
  listing it; `Roux.Lang.Manifest.memo_entries/1` decodes a loaded
  manifest's entries for inspection. `Roux.Memo.restore/2` is gone.

## 0.1.2 — 2026-09-16

### Changed (performance)

- **A hit hands back the value it already served.** Serving a memo hit
  read the whole entry out of ETS — a deep copy of the value — and then
  read it twice more (once after validation, once to propagate
  durability). A query graph that reads one large value many times per
  revision (scry reads each module's fact map once per relation, 47,000
  times on a 600-module project) paid a full copy every time. Values are
  now cached on the serving process, keyed by the entry's `changed_at`
  (a key executes at most once per revision and takes a new `changed_at`
  whenever its value changes), and durability is read through a field
  accessor. `Roux.Runtime.drop_cached_values/1` releases a process's
  copies for one database; `Roux.Memo.changed_at/2` and
  `Roux.Memo.durability/2` are the new accessors.

## 0.1.1 — 2026-09-11

### Changed

- Elixir requirement lowered to `~> 1.18`; OTP 28 remains required.

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
