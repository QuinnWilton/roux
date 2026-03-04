defmodule Roux.Entity do
  @moduledoc """
  Tracked structs with identity that persists across revisions.

  Rather than queries returning opaque values compared by structural equality,
  they create entities whose fields are individually tracked for changes. This
  enables finer-grained invalidation than opaque value comparison.

  ## Defining an entity

      defmodule MyLang.Function do
        use Roux.Entity,
          identity: [:name],
          tracked: [:body, :return_type]
      end

  This generates a struct with all fields as enforced keys and `__entity__/1`
  callbacks that return schema metadata.

  ## Entity lifecycle

  1. `create/4` interns the identity key and inserts or updates the entity.
  2. `field/4` reads a single field value.
  3. `field_changed_at/4` reads the revision at which a field last changed.
  4. `lookup/3` performs a non-interning lookup by identity key.

  Field-level dependency tracking is deferred to `Roux.Runtime`.
  """

  alias Roux.{Database, Intern}

  @type entity_id :: Intern.id()

  @type field_entry :: %{
          value: term(),
          hash: integer(),
          changed_at: Roux.Revision.revision()
        }

  # -- Macro ------------------------------------------------------------------

  @doc false
  defmacro __using__(opts) do
    identity = Keyword.get(opts, :identity)
    tracked = Keyword.get(opts, :tracked)

    validate_opts!(identity, tracked)

    all_fields = identity ++ tracked

    quote do
      @enforce_keys unquote(all_fields)
      defstruct unquote(all_fields)

      @doc false
      @spec __entity__(:identity_fields | :tracked_fields | :all_fields) :: [atom()]
      def __entity__(:identity_fields), do: unquote(identity)
      def __entity__(:tracked_fields), do: unquote(tracked)
      def __entity__(:all_fields), do: unquote(all_fields)
    end
  end

  defp validate_opts!(identity, tracked) do
    unless is_list(identity) and identity != [] do
      raise ArgumentError,
            "use Roux.Entity requires a non-empty :identity list, got: #{inspect(identity)}"
    end

    unless is_list(tracked) do
      raise ArgumentError,
            "use Roux.Entity requires a :tracked list, got: #{inspect(tracked)}"
    end

    unless Enum.all?(identity, &is_atom/1) do
      raise ArgumentError,
            ":identity fields must be atoms, got: #{inspect(identity)}"
    end

    unless Enum.all?(tracked, &is_atom/1) do
      raise ArgumentError,
            ":tracked fields must be atoms, got: #{inspect(tracked)}"
    end

    overlap = identity -- (identity -- tracked)

    unless overlap == [] do
      raise ArgumentError,
            "identity and tracked fields must not overlap, found: #{inspect(overlap)}"
    end
  end

  # -- Data operations --------------------------------------------------------

  @doc """
  Creates or updates an entity, returning its interned ID.

  Interns the identity key from `attrs` to produce a stable `entity_id`. If
  the entity is new, all fields are inserted with `changed_at` set to
  `revision`. If the entity already exists, only tracked fields whose values
  have actually changed get their `changed_at` updated.

  Uses a hash pre-check (D8) to avoid structural comparison when values differ.

  Raises `ArgumentError` if `module` is not registered as an entity type.
  Raises `KeyError` if `attrs` is missing a required field.
  """
  @spec create(Database.t(), module(), map(), Roux.Revision.revision()) :: entity_id()
  def create(%Database{} = db, module, attrs, revision)
      when is_atom(module) and is_map(attrs) and is_integer(revision) do
    table = entity_table!(db, module)
    intern_table = Database.intern_table(db, module)

    identity_fields = module.__entity__(:identity_fields)
    tracked_fields = module.__entity__(:tracked_fields)
    all_fields = module.__entity__(:all_fields)

    # Build identity key and intern it.
    identity_key = identity_fields |> Enum.map(&Map.fetch!(attrs, &1)) |> List.to_tuple()
    entity_id = Intern.intern(intern_table, identity_key)

    # Build the initial fields map for all fields.
    fields_map = build_fields_map(all_fields, attrs, revision)

    # Try to insert as a new entity.
    case :ets.insert_new(table, {entity_id, fields_map, 0}) do
      true ->
        entity_id

      false ->
        # Entity already exists — update only changed tracked fields.
        [{^entity_id, old_fields, _refcount}] = :ets.lookup(table, entity_id)
        new_fields = merge_tracked_fields(old_fields, tracked_fields, attrs, revision)
        :ets.update_element(table, entity_id, {2, new_fields})
        entity_id
    end
  end

  @doc """
  Reads a single field value from an entity.

  Raises `ArgumentError` if the entity does not exist or the field is unknown.
  """
  @spec field(Database.t(), module(), entity_id(), atom()) :: term()
  def field(%Database{} = db, module, entity_id, field_name)
      when is_atom(module) and is_integer(entity_id) and is_atom(field_name) do
    entry = field_entry!(db, module, entity_id, field_name)
    entry.value
  end

  @doc """
  Returns the revision at which a field last changed.

  Raises `ArgumentError` if the entity does not exist or the field is unknown.
  """
  @spec field_changed_at(Database.t(), module(), entity_id(), atom()) ::
          Roux.Revision.revision()
  def field_changed_at(%Database{} = db, module, entity_id, field_name)
      when is_atom(module) and is_integer(entity_id) and is_atom(field_name) do
    entry = field_entry!(db, module, entity_id, field_name)
    entry.changed_at
  end

  @doc """
  Non-interning lookup of an entity by its identity key.

  Returns `{:ok, entity_id}` if the identity key has been interned,
  `:error` otherwise. Does not create the identity mapping.
  """
  @spec lookup(Database.t(), module(), tuple()) :: {:ok, entity_id()} | :error
  def lookup(%Database{} = db, module, identity_key)
      when is_atom(module) and is_tuple(identity_key) do
    intern_table = Database.intern_table(db, module)
    Intern.lookup(intern_table, identity_key)
  end

  @doc """
  Returns the full fields map for an entity.

  Returns `{:ok, fields_map}` if the entity exists, `:error` otherwise.
  """
  @spec get_fields(Database.t(), module(), entity_id()) ::
          {:ok, %{atom() => field_entry()}} | :error
  def get_fields(%Database{} = db, module, entity_id)
      when is_atom(module) and is_integer(entity_id) do
    table = entity_table!(db, module)

    case :ets.lookup(table, entity_id) do
      [{^entity_id, fields_map, _refcount}] -> {:ok, fields_map}
      [] -> :error
    end
  end

  @doc """
  Removes an entity from the ETS table.

  No-op if the entity does not exist.
  """
  @spec delete(Database.t(), module(), entity_id()) :: :ok
  def delete(%Database{} = db, module, entity_id)
      when is_atom(module) and is_integer(entity_id) do
    table = entity_table!(db, module)
    :ets.delete(table, entity_id)
    :ok
  end

  # -- Refcount operations (D15) ----------------------------------------------

  @doc """
  Increments the reference count for an entity by 1.
  """
  @spec increment_refcount(Database.t(), module(), entity_id()) :: non_neg_integer()
  def increment_refcount(%Database{} = db, module, entity_id)
      when is_atom(module) and is_integer(entity_id) do
    table = entity_table!(db, module)
    :ets.update_counter(table, entity_id, {3, 1})
  end

  @doc """
  Decrements the reference count for an entity by 1, clamped at 0.
  """
  @spec decrement_refcount(Database.t(), module(), entity_id()) :: non_neg_integer()
  def decrement_refcount(%Database{} = db, module, entity_id)
      when is_atom(module) and is_integer(entity_id) do
    :ets.update_counter(entity_table!(db, module), entity_id, {3, -1, 0, 0})
  end

  @doc """
  Returns the current reference count for an entity.

  Raises `ArgumentError` if the entity does not exist.
  """
  @spec refcount(Database.t(), module(), entity_id()) :: non_neg_integer()
  def refcount(%Database{} = db, module, entity_id)
      when is_atom(module) and is_integer(entity_id) do
    table = entity_table!(db, module)

    case :ets.lookup(table, entity_id) do
      [{^entity_id, _fields, count}] -> count
      [] -> raise ArgumentError, "entity #{inspect(entity_id)} not found in #{inspect(module)}"
    end
  end

  @doc """
  Returns `true` if the entity has a positive reference count.

  Raises `ArgumentError` if the entity does not exist.
  """
  @spec alive?(Database.t(), module(), entity_id()) :: boolean()
  def alive?(%Database{} = db, module, entity_id)
      when is_atom(module) and is_integer(entity_id) do
    refcount(db, module, entity_id) > 0
  end

  @doc """
  Returns all entity rows for a registered entity type.

  Used by manifest serialization. Returns raw ETS rows as a list of
  `{entity_id, fields_map, refcount}` tuples.
  """
  @spec snapshot(Database.t(), module()) :: list()
  def snapshot(%Database{} = db, module) when is_atom(module) do
    table = entity_table!(db, module)
    :ets.tab2list(table)
  end

  @doc """
  Bulk-inserts entity rows for a registered entity type.

  Used by manifest restore. Registers the entity type if not already
  registered, then inserts all rows.
  """
  @spec restore(Database.t(), module(), list()) :: :ok
  def restore(%Database{} = db, module, rows) when is_atom(module) and is_list(rows) do
    Database.register_entity(db, module)
    table = entity_table!(db, module)
    :ets.insert(table, rows)
    :ok
  end

  # -- Private ----------------------------------------------------------------

  # Looks up the per-type ETS table from the entity registry.
  defp entity_table!(%Database{entity_registry: reg}, module) do
    case :ets.lookup(reg, module) do
      [{^module, tid}] ->
        tid

      [] ->
        raise ArgumentError,
              "entity type #{inspect(module)} is not registered — " <>
                "call Database.register_entity/2 first"
    end
  end

  # Builds the initial fields map for a new entity.
  defp build_fields_map(all_fields, attrs, revision) do
    Map.new(all_fields, fn field_name ->
      value = Map.fetch!(attrs, field_name)

      {field_name, %{value: value, hash: :erlang.phash2(value), changed_at: revision}}
    end)
  end

  # Merges new tracked field values into the existing fields map.
  # Identity fields are never updated — they are immutable by definition.
  defp merge_tracked_fields(old_fields, tracked_fields, attrs, revision) do
    Enum.reduce(tracked_fields, old_fields, fn field_name, fields ->
      new_value = Map.fetch!(attrs, field_name)
      new_hash = :erlang.phash2(new_value)
      old_entry = Map.fetch!(fields, field_name)

      if new_hash == old_entry.hash and new_value == old_entry.value do
        # Unchanged — keep old entry with original changed_at.
        fields
      else
        # Changed (different hash, or hash collision with different value).
        Map.put(fields, field_name, %{
          value: new_value,
          hash: new_hash,
          changed_at: revision
        })
      end
    end)
  end

  # Reads a single field entry, raising on missing entity or unknown field.
  defp field_entry!(%Database{} = db, module, entity_id, field_name) do
    table = entity_table!(db, module)

    case :ets.lookup(table, entity_id) do
      [{^entity_id, fields_map, _refcount}] ->
        case Map.fetch(fields_map, field_name) do
          {:ok, entry} ->
            entry

          :error ->
            raise ArgumentError,
                  "unknown field #{inspect(field_name)} on entity #{inspect(module)}"
        end

      [] ->
        raise ArgumentError,
              "entity #{inspect(entity_id)} not found in #{inspect(module)}"
    end
  end
end
