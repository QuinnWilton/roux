# Subsystem: Mix compiler

Module: `Roux.Lang.Compiler`

## Purpose

Integration with Mix's compiler system. Each registered Roux language adds a Mix compiler that detects stale files, updates inputs, and pulls compilation queries. The shim is intentionally thin — all incrementality logic lives in Roux, not in Mix's staleness tracking.

## Dependencies

- `Roux.Lang` — language behaviour
- `Roux.Database` — query execution
- `Roux.Input` — updating source inputs

## Usage

In a project's `mix.exs`:

```elixir
def project do
  [
    compilers: [:roux] ++ Mix.compilers(),
    # ...
  ]
end

# In config or mix.exs:
config :roux,
  languages: [MyLang, AnotherLang]
```

The `:roux` compiler runs before the standard Elixir compiler. Custom language modules are compiled to `.beam` files in `_build` before the Elixir compiler sees them.

## Mix compiler behaviour

```elixir
defmodule Roux.Lang.Compiler do
  use Mix.Task.Compiler

  @manifest_vsn 1

  @impl true
  def run(_argv) do
    languages = Application.get_env(:roux, :languages, [])

    # 1. Load or create the database.
    #    In batch `mix compile`: load from manifest if available.
    #    In `iex -S mix` / LSP: reuse existing in-memory database.
    db = get_or_create_database()

    # 2. Register all configured languages
    Enum.each(languages, &Roux.Lang.register(db, &1))

    # 3. Find all source files and detect which changed via mtimes
    all_sources = find_sources(languages)
    stale_sources = extract_stale_sources(all_sources, manifest_path())

    # 4. Update inputs only for changed files
    for path <- stale_sources do
      content = File.read!(path)
      Roux.Input.set(db, :source_text, path, content)
    end

    # 5. Detect removed files (in previous manifest but no longer on disk)
    detect_and_remove_deleted(db, all_sources, manifest_path())

    # 6. Pull compilation queries — validation pipeline handles the rest
    results =
      for lang <- languages,
          ext <- lang.file_extensions(),
          path <- source_files(ext) do
        Roux.Runtime.execute(db, lang.compile_query(), path)
      end

    # 7. Write .beam outputs to _build
    write_beam_outputs(results)

    # 8. Write manifest for next compile
    write_manifest(db, all_sources)

    # 9. Collect diagnostics
    collect_diagnostics(db, languages)
  end

  @impl true
  def manifests, do: [manifest_path()]

  @impl true
  def clean do
    File.rm(manifest_path())
  end

  defp manifest_path do
    Path.join(Mix.Project.manifest_path(), "compile.roux")
  end
end
```

## Staleness detection

Roux uses Mix's manifest infrastructure to persist compiler state across VM restarts. This enables incremental batch compilation — not just incremental within a running VM.

### How it works

The manifest file (`_build/dev/lib/<app>/.mix/compile.roux`) stores:

1. **Source file metadata**: path, mtime, content hash for each source file.
2. **Memo table snapshot**: serialized memo entries (query key, value, value hash, changed_at, dependencies, output_entities).
3. **Entity table snapshot**: entity data for live entities.
4. **Revision counter state**: so the revision timeline is continuous across restarts.

### Compilation flow

**With manifest (warm batch compile):**

1. Load manifest → populate memo table and entity tables from snapshot.
2. Compare source file mtimes against manifest metadata.
3. Unchanged files: skip entirely (memo entries already loaded, inputs already valid).
4. Changed files: read content, call `Roux.Input.set/4` (content hash comparison provides early cutoff even if mtime changed but content didn't).
5. Removed files: call `Roux.GC.mark_input_removed/3`.
6. Pull compilation queries — the normal validation/early-cutoff pipeline runs. Most queries validate as fresh and return cached results. Only queries transitively downstream of changed inputs re-execute.
7. Write updated manifest.

**Without manifest (clean build):**

1. Create fresh database, read all source files, evaluate all queries from scratch.
2. Write manifest for next compile.

**Nothing changed (most common case):**

1. Load manifest, check mtimes — no stale sources detected.
2. Pull compilation queries — all validate as fresh immediately.
3. Return `{:noop, []}`.

### What goes in the manifest

The durability system (see [02-revision.md](02-revision.md)) provides a natural filter:

| Durability | Persist? | Rationale |
|-----------|----------|-----------|
| High | Yes | Parsing, type signatures — expensive, rarely change |
| Medium | Yes | Resolved references, diagnostics — moderately expensive |
| Low | No | Hover info, completions — cheap to recompute, not needed for batch compile |

### Manifest format

Uses `:erlang.term_to_binary/2` and `:erlang.binary_to_term/1`, same as the Elixir compiler's manifest. A `@manifest_vsn` tag enables graceful migration — if the version doesn't match, the manifest is discarded and a full rebuild runs.

### Why not just use Roux's content comparison?

The earlier design read all source files unconditionally and relied on `Input.set/4` content comparison. This works but is wasteful:

- Reading 1000 files to discover 1 changed is unnecessary when mtimes are available.
- Without a manifest, there are no memo entries to validate against, so every query must evaluate from scratch regardless.

Mix's mtime tracking is the fast pre-filter. Roux's content-hash comparison (inside `Input.set/4`) is the precise filter for files whose mtime changed but content didn't (e.g., `touch` without edits).

## Ordering with Elixir compiler

Custom languages compile BEFORE the Elixir compiler:

```
compilers: [:roux, :elixir, :app]
```

Roux writes `.beam` files to `_build/dev/lib/<app>/ebin/`. The Elixir compiler then sees these as already-compiled modules and can reference them.

For the reverse direction (custom language depends on Elixir modules), the Elixir compiler must run first. This is a chicken-and-egg problem. Solutions:

1. **Two-pass**: Run Elixir compiler first (ignoring custom lang files), then Roux, then Elixir again.
2. **Declaration-only pass**: Roux extracts module interfaces from Elixir source without full compilation.
3. **Defer to the user**: Document that cross-language dependencies must flow in one direction.

**Start with option 3.** Cross-language bidirectional dependencies are rare and can be addressed later.

## Database lifecycle

Each `mix compile` from the terminal starts a fresh BEAM VM, so in-memory state does not survive between invocations. The manifest bridges this gap for batch compilation. For long-lived VM sessions, the database persists in memory.

| Context | Database source | Incrementality |
|---------|----------------|----------------|
| `mix compile` (first time) | Fresh, no manifest | Full evaluation |
| `mix compile` (subsequent) | Loaded from manifest | Incremental — only changed files trigger recomputation |
| `iex -S mix` + `recompile()` | In-memory, persists for session | Incremental |
| LSP server | In-memory, persists for session | Incremental |
| `mix clean` + `mix compile` | Fresh, manifest deleted | Full evaluation |

### Interactive session (`iex -S mix`)

The database is created once when `iex` starts and persists for the session lifetime via a named process or `:persistent_term`. Subsequent `recompile()` calls get warm starts. The manifest is also written after each compile so switching to batch `mix compile` picks up the cached state.

### LSP server

The LSP server (see [16-lsp.md](16-lsp.md)) maintains a long-lived database for the entire editing session. This is where incremental computation provides the most value — sub-second feedback on file edits.

### What to defer

Manifest persistence is not needed for the core framework to work. **Implement the in-memory incremental pipeline first (Tiers 0–3), then add manifest serialization.**

Without a manifest, batch `mix compile` is a full rebuild — the same behavior as standard Mix compilers today. The manifest is an optimization, not a correctness requirement.

The data model already carries everything needed for serialization (values, hashes, dependencies, durability levels), so adding the manifest later doesn't require structural changes.

## Implementation notes

- The compiler should return `{:ok, diagnostics}` or `{:error, diagnostics}` per Mix.Task.Compiler convention.
- Source files are found by walking the `elixirc_paths` (or a custom `:roux_paths` config) looking for files with registered extensions.

## Testing strategy

### Unit tests
- Compiler detects source files by extension
- Input values are updated for changed files
- Unchanged files do not trigger recomputation
- Beam outputs are written to correct location

### Integration tests
- Create a Mix project with a custom language, run `mix compile`, verify outputs
- Cold start (no manifest): fresh database produces correct outputs
- Warm start (`iex -S mix` + `recompile()`): edit a file, recompile, verify only affected queries re-run
- Delete a file, recompile, verify cleanup
- `mix clean` followed by `mix compile` produces identical outputs

### Manifest tests
- `manifests/0` returns the correct path
- `clean/0` removes the manifest file
- Compile writes a manifest; second compile loads it and skips unchanged queries
- Edit one file between compiles — only affected queries re-execute
- Delete a file between compiles — removed input triggers downstream cleanup
- Corrupt manifest — falls back to full rebuild gracefully
- Manifest with wrong `@manifest_vsn` — discarded, full rebuild
- Touch a file without changing content — mtime changes but content hash matches, no recomputation
