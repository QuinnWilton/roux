# roux

[![CI](https://github.com/QuinnWilton/roux/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/roux/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/roux.svg)](https://hex.pm/packages/roux)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/roux)

A framework for building incremental mix compilers.

## Installation

```elixir
def deps do
  [
    {:roux, "~> 0.1.0"}
  ]
end
```

## Usage

Queries are pure functions from a key to a value. Roux memoizes them,
records which inputs and queries each one read, and on the next demand
re-executes only what a changed input can reach — stopping early wherever
a recomputed value equals the memoized one.

```elixir
defmodule MyLang do
  use Roux.Query

  alias Roux.Runtime

  definput(:source_text, durability: :low)

  defquery :parsed, key: path, returns: {:ok, term()} | {:error, term()} do
    Runtime.input!(db, :source_text, path)
    |> Code.string_to_quoted()
  end

  defquery :declared_modules, key: path, returns: [module()] do
    case Runtime.query(db, :parsed, path) do
      {:ok, ast} -> MyLang.Ast.modules(ast)
      {:error, _} -> []
    end
  end
end

db = Roux.Database.new()
:ok = Roux.Lang.register_module(db, MyLang)

Roux.Input.set(db, :source_text, "lib/a.ex", "defmodule A do end")
Roux.Runtime.query(db, :declared_modules, "lib/a.ex")
#=> [A]

# A whitespace-only edit re-parses the file, but `parsed` returns an
# equal AST, so `declared_modules` is validated without executing.
Roux.Input.set(db, :source_text, "lib/a.ex", "defmodule A do\nend")
Roux.Runtime.query(db, :declared_modules, "lib/a.ex")
#=> [A]
```

`Roux.Lang` is the convention layer for compilers built this way: a
behaviour naming the compile and diagnostics queries, a Mix compiler shim
with a persisted manifest for cross-run incrementality (`Roux.Lang.Manifest`),
and a generic LSP adapter over `gen_lsp`. See
[`docs/architecture.md`](docs/architecture.md) for the design and
[`docs/subsystems/`](docs/subsystems/) for each layer.

## Background & prior art

Roux ports **Salsa** — Niko Matsakis's Rust framework for incremental,
demand-driven computation, generalized from rustc's "red-green" query engine (the
reason rust-analyzer feels instant) — to the BEAM. Salsa is not a paper; the idea
lived only as engineering, inside one compiler, in one language. The academic
roots:

- **Adapton: Composable, Demand-Driven Incremental Computation** — Hammer, Khoo,
  Hicks & Foster, *PLDI 2014* — change propagation over a demand-driven dependency
  graph.
- **Self-Adjusting Computation** — Umut Acar, PhD thesis, CMU 2005; Acar, Blelloch
  & Harper, *Adaptive Functional Programming*, *POPL 2002*.
- **Build Systems à la Carte** — Mokhov, Mitchell & Peyton Jones, *ICFP 2018* —
  situates roux's early-cutoff/rebuild design in the incremental-build design space.

The critical correctness property (incremental result equals batch result) is
property-tested.

## License

MIT
