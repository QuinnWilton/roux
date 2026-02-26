# Subsystem: Input

Module: `Roux.Input`

## Purpose

Inputs are values provided from outside the computation — source file contents, configuration, environment variables. They form the leaves of the dependency graph. Setting an input advances the global revision counter and records which durability level changed.

## Dependencies

- `Roux.Database` — storage
- `Roux.Revision` — revision counter and durability tracking
- `Roux.Memo` — memo entries for input values
- `Roux.Telemetry` — emits `[:roux, :input, :set]` and `[:roux, :input, :delete]` events

## Key types

```elixir
defmodule Roux.Input do
  @type definition :: %__MODULE__.Definition{
    name: atom(),
    durability: Roux.Revision.durability()
  }
end
```

## Public API

```elixir
@spec define(atom(), keyword()) :: definition()
# Create an input definition.
# Options:
#   :durability — :high | :medium | :low (default: :medium)

@spec register(Roux.Database.t(), definition()) :: :ok
# Register an input definition with the database.

@spec set(Roux.Database.t(), input_name :: atom(), key :: term(), value :: term()) :: :ok
# Set an input value. If the value is different from the current value,
# advances the revision counter at the input's durability level.
# If the value is the same (early cutoff at the input level), no revision advance.

@spec get(Roux.Database.t(), input_name :: atom(), key :: term()) :: term()
# Read an input value. Records a dependency in the active query context.
# Raises if the input has never been set for this key.

@spec get_with_revision(Roux.Database.t(), input_name :: atom(), key :: term()) ::
        {term(), Roux.Revision.revision()}
# Read an input value along with the revision at which it was last changed.

@spec delete(Roux.Database.t(), input_name :: atom(), key :: term()) :: :ok
# Remove an input value. Advances the revision counter.

@spec keys(Roux.Database.t(), input_name :: atom()) :: [term()]
# List all keys for an input. Used by the Mix compiler to enumerate source files.
```

## Usage

### With the `definput` macro (via `use Roux.Query`)

```elixir
defmodule MyLang.Queries do
  use Roux.Query

  # Inputs are defined alongside derived queries.
  # durability controls how aggressively validation can skip this input's subgraph.
  definput :source_text, durability: :low
  definput :project_config, durability: :high

  defquery :parse, key: file_path do
    source = input(db, :source_text, file_path)
    MyParser.parse(source)
  end
end

# Registration handles both inputs and queries:
db = Roux.Database.new()
Roux.Database.register_module(db, MyLang.Queries)

# Set input values from outside the query graph:
Roux.Input.set(db, :source_text, "lib/foo.ex", "defmodule Foo do\nend")
Roux.Input.set(db, :project_config, :target, :elixir_ast)
```

### With plain functions (no macros)

```elixir
# Define and register manually:
source_input = Roux.Input.define(:source_text, durability: :low)
config_input = Roux.Input.define(:project_config, durability: :high)

db = Roux.Database.new()
Roux.Input.register(db, source_input)
Roux.Input.register(db, config_input)

# Set values:
Roux.Input.set(db, :source_text, "lib/foo.ex", "defmodule Foo do\nend")

# Read values (outside a query — no dependency tracking):
content = Roux.Input.get(db, :source_text, "lib/foo.ex")

# List all files that have been set:
files = Roux.Input.keys(db, :source_text)
# => ["lib/foo.ex"]

# Remove a file (e.g., it was deleted):
Roux.Input.delete(db, :source_text, "lib/foo.ex")
```

### Typical input patterns

| Input | Key | Value | Durability |
|-------|-----|-------|-----------|
| Source file contents | file path | binary string | `:low` (edited file) or `:medium` (other files) |
| Project configuration | config key atom | config value | `:high` |
| Standard library types | module name | type signatures | `:high` |
| CLI flags | flag name | flag value | `:high` |

Note that durability is per input *definition*, not per key. If the currently-edited file and background files need different durability, they should be separate inputs (e.g., `:active_source` at `:low` and `:source_text` at `:medium`).

## Input vs. derived queries

Inputs are stored as memo entries in the same table as derived queries, but with key differences:

- Inputs have no dependency list (they are leaves).
- Inputs are set explicitly by the user, not computed by a function.
- Setting an input always updates `changed_at` and `verified_at` to the new revision (no validation needed).
- Inputs carry a durability level from their definition.

The query key for an input is `{:input, input_name, key}` to distinguish from derived queries `{query_name, key}`.

## Early cutoff at the input level

When `set/4` is called, compare the new value to the old value *before* advancing the revision:

1. If no previous value exists: store it, advance revision.
2. If previous value exists and `new_value == old_value`: do nothing (no revision advance).
3. If previous value exists and values differ: store new value, advance revision.

This prevents cascading recomputation when a file is saved without changes.

## Implementation notes

- Input definitions are stored in the `input_registry` ETS table in the database.
- The `:input` prefix in query keys ensures no collision with derived query names.
- The `definput` macro (defined in `Roux.Query`) is syntactic sugar for `Roux.Input.define/2` + `Roux.Input.register/2`.
- When `get/3` is called during query execution, it must record the dependency `{:input, input_name, key}` in the active context. If called outside a query context, it just reads the value.

## Testing strategy

### Unit tests
- Define and register input
- Set and get round-trip
- Setting the same value twice does not advance revision
- Setting a different value advances revision
- Get on unset key raises
- Delete removes value and advances revision
- Keys returns all set keys

### Integration tests
- Set input, query derived value, change input, observe derived query re-executes
- Set input to same value, verify derived query does NOT re-execute
