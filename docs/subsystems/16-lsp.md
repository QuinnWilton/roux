# Subsystem: LSP adapter

Module: `Roux.Lang.LSP`

## Purpose

A generic LSP server that delegates to query-based language implementations. IDE features become queries in the same database, sharing all memoized intermediate results with compilation. Built on `gen_lsp`.

## Dependencies

- `Roux.Lang` — language behaviour (optional callbacks for IDE features)
- `Roux.Database` — query execution
- `gen_lsp` — LSP protocol implementation

## Architecture

```
Editor (VS Code, Neovim, etc.)
    │ LSP protocol (JSON-RPC over stdio)
    ▼
Roux.Lang.LSP (GenLSP server)
    │ Query calls
    ▼
Roux.Database
    │ Memoized queries
    ▼
Language implementations
```

The LSP server:

1. Receives editor events (file open, edit, save, hover, completion request).
2. Translates them to input updates and query calls.
3. Returns results formatted per the LSP protocol.

## IDE features as queries

| LSP feature | Roux query | Trigger |
|-------------|-----------|---------|
| Diagnostics | `lang.diagnostics_query()` | After each revision (file change) |
| Completions | `lang.completions_query()` | `textDocument/completion` request |
| Hover | `lang.hover_query()` | `textDocument/hover` request |
| Go-to-definition | `lang.definition_query()` | `textDocument/definition` request |

Because these are queries in the same database, they share cached intermediate results. Computing completions after an edit reuses the cached parse tree and name resolution from the last compilation, only re-executing what actually changed.

## File synchronization

The LSP server maintains source file contents as inputs:

```
textDocument/didOpen   → Input.set(db, :source_text, uri, content)   durability: :low
textDocument/didChange → Input.set(db, :source_text, uri, new_content)  durability: :low
textDocument/didClose  → restore from disk, set durability: :medium
textDocument/didSave   → update durability: :medium (saved = no longer volatile)
```

Durability transitions:
- File opened in editor: `:medium` → `:low` (now being edited)
- File closed: `:low` → `:medium` (back to disk version)
- This is a simplification — the full durability model may need per-key durability tracking.

## Diagnostic push

After each input change, the server:

1. Waits for a debounce period (e.g., 100ms) to batch rapid edits.
2. For each file with changes, calls the diagnostics query.
3. Pushes diagnostics to the editor via `textDocument/publishDiagnostics`.

Because of early cutoff, unchanged files produce cached diagnostics instantly.

## Cancellation integration

When the user types rapidly:

1. Each keystroke calls `Input.set(db, :source_text, uri, new_content)`.
2. `Input.set` triggers `Cancellation.cancel_dependents(db, {:input, :source_text, uri})`.
3. In-flight diagnostic/completion computations for this file are cancelled.
4. New computations start from the latest revision.

This ensures the LSP server is always working on the latest state, not computing stale results.

## Position mapping

LSP uses `{line, character}` positions (0-indexed). Pentiment uses `{line, column}` (1-indexed). The LSP adapter handles this conversion at the boundary:

```elixir
defp lsp_to_pentiment(%{"line" => line, "character" => col}) do
  Pentiment.Span.position(line + 1, col + 1)
end

defp pentiment_to_lsp(%Pentiment.Span.Position{start_line: line, start_column: col}) do
  %{"line" => line - 1, "character" => col - 1}
end
```

## Implementation notes

- The LSP server is a `GenLSP` process that owns a `Roux.Database`.
- The database persists for the lifetime of the LSP server process.
- Multi-language support: a single LSP server can handle multiple languages registered in the same database.
- The debounce timer should be configurable.
- Error handling: if a query raises, the LSP server logs the error and returns empty results (not crash).

## Testing strategy

### Unit tests
- Position conversion (LSP ↔ pentiment)
- Input synchronization (didOpen, didChange, didClose)
- Diagnostic formatting

### Integration tests
- Start LSP server, send didOpen, verify diagnostics
- Edit file, verify diagnostics update
- Hover request returns type info
- Completion request returns candidates
- Rapid edits: verify cancellation and fresh results

### Protocol conformance
- Use gen_lsp's test helpers to verify LSP protocol compliance
