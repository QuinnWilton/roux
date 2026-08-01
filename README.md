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

TODO

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
property-tested. Full citations with DOIs:
[`../keynote/citations.md`](../keynote/citations.md).

## License

MIT
