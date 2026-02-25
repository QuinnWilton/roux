# Subsystem: Lang

Module: `Roux.Lang`

## Purpose

A thin convention layer that defines what it means to be a "language" in the Roux ecosystem. Languages implement a behaviour that specifies file extensions, query registrations, and entry points. `Roux.Lang` is not required to use Roux — it's a convenience for the common case of building compilers.

## Dependencies

- `Roux.Database` — query registration
- `Roux.Query` — query definitions
- `Roux.Input` — input definitions

## The behaviour

```elixir
defmodule Roux.Lang do
  @type source_path :: String.t()
  @type module_interface :: term()  # language-specific, opaque to the framework

  @doc "File extensions this language handles (e.g., [\".myex\", \".myl\"])"
  @callback file_extensions() :: [String.t()]

  @doc "Register all queries for this language with the database."
  @callback register_queries(Roux.Database.t()) :: :ok

  @doc "The query name that compiles a single file. Called by the Mix compiler."
  @callback compile_query() :: atom()

  # Optional IDE support callbacks

  @doc "Query that produces diagnostics for a file."
  @callback diagnostics_query() :: atom()

  @doc "Query that produces completions at a position."
  @callback completions_query() :: atom()

  @doc "Query that produces hover info at a position."
  @callback hover_query() :: atom()

  @doc "Query that produces go-to-definition results."
  @callback definition_query() :: atom()

  @optional_callbacks [
    diagnostics_query: 0,
    completions_query: 0,
    hover_query: 0,
    definition_query: 0
  ]
end
```

## Usage

```elixir
defmodule MyLang do
  @behaviour Roux.Lang
  use Roux.Query

  @impl true
  def file_extensions, do: [".ml"]

  @impl true
  def compile_query, do: :compile

  @impl true
  def register_queries(db) do
    Roux.Database.register_module(db, __MODULE__)
  end

  definput :source_text, durability: :low

  defquery :parse, key: file_path do
    source = input(db, :source_text, file_path)
    MyLang.Parser.parse(source)
  end

  defquery :compile, key: file_path do
    ast = query(db, :parse, file_path)
    MyLang.Codegen.compile(ast)
  end
end
```

## Cross-language module interface

When multiple languages coexist in a project, they may need to reference each other's exports. `Roux.Lang` provides a protocol for this:

```elixir
@doc "Return the public interface of a compiled module."
@callback module_interface(Roux.Database.t(), source_path()) :: module_interface()

@optional_callbacks [module_interface: 2]
```

The consuming language doesn't need to know how a module was compiled. The framework resolves which language owns a given source file (by extension) and dispatches to the appropriate `module_interface` query.

```elixir
# In the framework:
def resolve_interface(db, source_path) do
  lang = lang_for_extension(db, Path.extname(source_path))
  lang.module_interface(db, source_path)
end
```

## Language registration

Languages are registered with a database:

```elixir
db = Roux.Database.new()
Roux.Lang.register(db, MyLang)
Roux.Lang.register(db, AnotherLang)
```

Registration:
1. Calls `lang.register_queries(db)` to register all queries.
2. Records the language and its file extensions in the database.
3. Validates no extension conflicts (two languages claiming `.ex`).

## Compilation output targets

Languages choose their own output target. The framework doesn't constrain this:

| Target | How to use |
|--------|-----------|
| Elixir AST | Return quoted expressions from the compile query. Caller uses `Code.compile_quoted/2`. |
| Erlang abstract format | Return abstract forms. Caller uses `:compile.forms/2`. |
| Core Erlang | Return core erlang forms. Caller uses `:compile.forms/2` with `:from_core`. |
| Raw BEAM | Return binary chunks. Caller writes `.beam` file directly. |

The Mix compiler shim (see [15-mix-compiler.md](./15-mix-compiler.md)) handles writing the output to `_build`.

## Implementation notes

- `Roux.Lang` is a plain behaviour module. No macros, no magic.
- Language modules can also `use Roux.Query` to get the `defquery`/`definput` macros.
- The module interface protocol is deliberately opaque — each language defines its own interface type. Type compatibility across languages is the language implementor's responsibility.

## Testing strategy

### Unit tests
- Implement a minimal language, register it, verify callbacks work
- Extension registration and conflict detection
- Cross-language interface resolution

### Integration tests
- Two languages in the same database, compiling files of different extensions
- Cross-language dependency (language A imports module from language B)
