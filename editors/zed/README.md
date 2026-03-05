# Roux LSP — Zed extension

A template Zed extension that wraps the Roux LSP server (`mix roux.lsp`).

## Setup

1. Ensure your Roux-based project compiles and `mix roux.lsp` runs.
2. In Zed, use "zed: install dev extension" and select this `editors/zed/` directory.
3. Add a language directory under `languages/` with a `config.toml` for your file type.
4. Update `extension.toml` to bind the language server to your language name.

## How it works

The extension finds `mix` on your PATH and runs `mix roux.lsp` as the language server process. The LSP server reads language configuration from your project's `:roux` application config.

## Customization

This extension is a template. To adapt it for your language:

- **`extension.toml`**: Change the extension id, name, and language server language binding.
- **`languages/<name>/config.toml`**: Set `path_suffixes` to your file extensions and configure comment syntax.
- **`src/lib.rs`**: The Rust code is generic and typically needs no changes. If your LSP binary is not `mix roux.lsp`, update the command and args.

## Building

Requires the Zed extension toolchain:

```bash
cargo build --release --target wasm32-wasip1
```

See [Zed extension docs](https://zed.dev/docs/extensions) for details on packaging and publishing.
