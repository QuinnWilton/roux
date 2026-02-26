# Subsystem: Entity

Module: `Roux.Entity`

## Purpose

Entities are structured values with identity that persists across revisions. Rather than queries returning opaque values compared by structural equality, they create entities whose fields are individually tracked for changes. This enables finer-grained invalidation than opaque value comparison.

See decision [D5](../decisions.md) for the behaviour-based metadata approach.

## Dependencies

- `Roux.Database` — entity ETS tables
- `Roux.Intern` — entity ID allocation

## Key types

```elixir
# Entity instance stored in ETS
@type entity_id :: Roux.Intern.id()

@type field_entry :: %{
  value: term(),
  hash: integer(),
  changed_at: Roux.Revision.revision()
}

# ETS row: {entity_id, %{field_name => field_entry}, refcount}
```

The `hash` field stores `:erlang.phash2/1` of the value for fast inequality
pre-check during field comparison (see [D8](../decisions.md)). The `refcount`
field tracks how many queries include this entity in their output set (see
[D15](../decisions.md)).

## Entity definition

```elixir
defmodule MyLang.Function do
  use Roux.Entity,
    identity: [:name],
    tracked: [:body, :return_type]
end
```

### What `use Roux.Entity` generates

```elixir
defmodule MyLang.Function do
  @enforce_keys [:name, :body, :return_type]
  defstruct [:name, :body, :return_type]

  @doc false
  def __entity__(:identity_fields), do: [:name]
  def __entity__(:tracked_fields), do: [:body, :return_type]
  def __entity__(:all_fields), do: [:name, :body, :return_type]
end
```

The struct is a plain Elixir struct. The `__entity__/1` function provides schema metadata that the runtime uses for identity matching and field tracking.

## Entity lifecycle

### Creation

During query execution, `Roux.Runtime.create/3` creates an entity:

1. Compute the **identity key**: a tuple of the entity's identity field values. For `MyLang.Function`, this is `{function_name}`.
2. Intern the identity key to get a stable `entity_id`.
3. Look up the entity in ETS by `entity_id`:
   - **New entity**: insert all fields with `changed_at = current_revision`.
   - **Existing entity**: for each tracked field, compare new value to old value.
     - Changed: update value and `changed_at` to current_revision.
     - Unchanged: keep existing value and `changed_at`.
4. Record the entity in the context's `created_entities` list.

### Field access

During query execution, `Roux.Runtime.field/3` reads an entity field:

1. Read the field value from ETS.
2. Record a **field-level dependency**: `{:entity_field, module, entity_id, field_name}`.

This means downstream queries only invalidate when the specific field they read changes.

### Identity matching

Identity matching uses interned identity keys. The identity key for an entity is `{module, identity_field_values_tuple}`. Interning this gives a stable integer ID that persists across revisions.

If a query creates entity `Function{name: :foo, body: ast1}` in revision 3, and then creates `Function{name: :foo, body: ast2}` in revision 5, the identity key `:foo` maps to the same entity ID. Only the `body` field is updated.

### Name collisions

If two entities of the same type have the same identity key (e.g., two functions named `:foo`), this is an error — the identity key must be unique within a type. The framework raises on collision during creation.

For cases where name collisions are expected (e.g., overloaded functions), the identity should include disambiguating information (arity, source file, etc.).

## Garbage collection integration

When a query re-executes, its `output_entities` may change. Entities in the old output set but not in the new output set are candidates for deletion. See [13-gc.md](./13-gc.md) for details.

## API for query authors

```elixir
# Inside a defquery block:

# Create an entity (records in output set, returns entity_id)
entity_id = create(db, MyLang.Function, %{name: :foo, body: ast, return_type: type})

# Read a field (records field-level dependency)
body = field(db, {MyLang.Function, entity_id}, :body)

# Look up an entity by identity key
entity_id = lookup(db, MyLang.Function, {:foo})
```

## Implementation notes

- Entity tables are per-type ETS `:set` tables with `read_concurrency: true` and `write_concurrency: true`.
- Entity creation during query execution is buffered in the context, like all writes.
- Identity keys are interned using a per-entity-type intern table.
- Field comparison uses the same hash pre-check as memo entries (see [D8](../decisions.md)).
- The identity key tuple is ordered by field definition order, not alphabetically.

## Testing strategy

### Unit tests
- Define entity, create instance, read fields
- Create same entity with changed field → field `changed_at` updates
- Create same entity with unchanged field → field `changed_at` stays
- Identity matching: same identity fields → same entity ID
- Different identity fields → different entity IDs
- Name collision detection (if applicable)

### Integration tests
- Query creates entity, downstream query reads field
- Entity field changes → downstream query re-executes
- Entity field unchanged → downstream query does NOT re-execute (early cutoff at field level)
- Query stops creating entity → entity is garbage collected

### Property tests
- For any sequence of entity create/update/read operations, field-level dependencies correctly track which downstream queries need re-execution
