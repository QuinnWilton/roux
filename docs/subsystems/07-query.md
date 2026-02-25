# Subsystem: Query

Module: `Roux.Query`

## Purpose

Derived query definition and the `defquery` macro. A derived query is a pure function from a key to a value that may call other queries. The framework memoizes results and tracks dependencies automatically.

See decision [D1](../decisions.md) for threaded context rationale.

## Dependencies

- `Roux.Database` — query registry

## Key types

```elixir
defmodule Roux.Query do
  @type query_name :: atom()

  @type definition :: %__MODULE__.Definition{
    name: query_name(),
    module: module(),
    function: atom(),
    opts: keyword()
  }
end
```

## Macro API

```elixir
defmodule MyLang.Queries do
  use Roux.Query

  # Define an input with durability
  definput :source_text, durability: :low
  definput :config, durability: :high

  # Define a derived query
  # The macro generates a function that takes (db, key) and wraps the body
  # in dependency tracking.
  defquery :parse, key: file_path do
    source = input(db, :source_text, file_path)
    MyParser.parse(source)
  end

  defquery :typecheck, key: file_path do
    ast = query(db, :parse, file_path)
    MyTypechecker.check(ast)
  end
end
```

### What the macro generates

`defquery :parse, key: file_path do ... end` expands to approximately:

```elixir
def parse(db, file_path) do
  Roux.Runtime.execute(db, :parse, file_path, fn db, file_path ->
    # ... user's query body, with `query/3` and `input/3` available
  end)
end

def __query_definition__(:parse) do
  %Roux.Query.Definition{
    name: :parse,
    module: __MODULE__,
    function: :parse,
    opts: []
  }
end
```

### Registration

`use Roux.Query` generates a `__roux_queries__/0` function that returns all query and input definitions in the module. This is called by `Roux.Database.register_module/2`:

```elixir
db = Roux.Database.new()
Roux.Database.register_module(db, MyLang.Queries)
# Registers all inputs and queries defined in the module
```

## Plain function API

The macro is implemented in terms of plain functions. Users who prefer not to use macros can:

```elixir
# Define a query as a plain function
def parse(db, file_path) do
  source = Roux.Input.get(db, :source_text, file_path)
  MyParser.parse(source)
end

# Register it manually
definition = Roux.Query.Definition.new(:parse, MyModule, :parse)
Roux.Database.register_query(db, definition)
```

The only difference is that manually-defined queries don't get automatic dependency tracking wrappers — the user must call `Roux.Runtime.execute/4` themselves.

## Within-query helpers

Inside a `defquery` block, these helpers are available:

```elixir
query(db, :query_name, key)   # Call another derived query (records dependency)
input(db, :input_name, key)   # Read an input (records dependency)
create(db, EntityMod, attrs)  # Create an entity (records in output set)
lookup(db, EntityMod, id)     # Look up an entity by ID
field(db, entity, :field)     # Read an entity field (records field-level dependency)
```

These are normal function calls that the macro imports into the block's scope.

## Implementation notes

- The `defquery` macro should be hygienic — it must not capture or leak variables.
- Query names must be unique within a database. Registering a duplicate raises.
- The query function itself must be pure (no side effects beyond calling other queries). The framework does not enforce this — it's a convention.
- Consider generating `@spec` annotations from the macro if type information is provided.

## Testing strategy

### Unit tests
- Macro expansion produces expected function definitions
- `__roux_queries__/0` lists all defined queries
- `__query_definition__/1` returns correct metadata
- Registration succeeds and query appears in registry
- Duplicate registration raises

### Macro tests
- Test with various key patterns (single key, multiple keys, destructured keys)
- Test that the macro is hygienic (no variable leakage)
- Test that generated functions are callable
