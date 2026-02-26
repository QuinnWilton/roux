defmodule Roux.Input do
  @moduledoc """
  External values that form the leaves of the dependency graph.

  Inputs represent values provided from outside the computation — source file
  contents, configuration, environment variables. Setting an input advances the
  global revision counter with early cutoff: if the new value equals the old
  value, no revision advance occurs.

  Input values are stored as memo entries with a `{:input, input_name, key}`
  query key, empty dependencies, and durability inherited from the input
  definition.

  ## Early cutoff

  When `set/4` is called with a value identical to the current value, no
  revision advance occurs. This prevents cascading recomputation when a file
  is saved without changes. Equality uses a hash pre-check (D8) to avoid
  structural comparison on large terms when values differ.
  """

  alias Roux.Database
  alias Roux.Input.{Definition, NotSetError}
  alias Roux.{Memo, Revision, Telemetry}
  alias Roux.Memo.Entry

  @type definition :: Definition.t()

  @doc """
  Creates an input definition. Default durability is `:medium`.

  ## Options

    * `:durability` — `:high`, `:medium`, or `:low` (default: `:medium`)

  """
  @spec define(atom(), keyword()) :: definition()
  def define(name, opts \\ []) when is_atom(name) do
    durability = Keyword.get(opts, :durability, :medium)

    %Definition{name: name, durability: durability}
  end

  @doc """
  Registers an input definition with the database.

  Must be called before `set/4` or `get/3` for this input.
  """
  @spec register(Database.t(), definition()) :: :ok
  def register(%Database{} = db, %Definition{name: name, durability: durability}) do
    Database.register_input(db, name, durability: durability)
  end

  @doc """
  Sets an input value with early cutoff.

  If the value is identical to the current value (hash pre-check, then
  structural equality), no revision advance occurs. Otherwise, the revision
  counter advances at the input's durability level.

  Raises `ArgumentError` if the input is not registered.
  """
  @spec set(Database.t(), atom(), term(), term()) :: :ok
  def set(%Database{} = db, input_name, key, value) when is_atom(input_name) do
    query_key = {:input, input_name, key}
    new_hash = :erlang.phash2(value)

    case Memo.get(db, query_key) do
      {:ok, %Entry{hash: old_hash, value: old_value}}
      when old_hash == new_hash and old_value == value ->
        :ok

      _miss_or_changed ->
        durability = lookup_durability!(db, input_name)
        new_rev = Revision.advance(db.revision, durability)

        entry = %Entry{
          value: value,
          hash: new_hash,
          changed_at: new_rev,
          verified_at: new_rev,
          dependencies: [],
          durability: durability,
          output_entities: []
        }

        Memo.put(db, query_key, entry)
        Telemetry.input_set(input_name, key, new_rev, durability)
        :ok
    end
  end

  @doc """
  Reads an input value.

  Raises `Roux.Input.NotSetError` if the key has never been set.
  Dependency tracking is deferred to runtime integration.
  """
  @spec get(Database.t(), atom(), term()) :: term()
  def get(%Database{} = db, input_name, key) when is_atom(input_name) do
    case Memo.get(db, {:input, input_name, key}) do
      {:ok, %Entry{value: value}} -> value
      :miss -> raise NotSetError, input_name: input_name, key: key
    end
  end

  @doc """
  Reads an input value along with the revision at which it last changed.

  Raises `Roux.Input.NotSetError` if the key has never been set.
  """
  @spec get_with_revision(Database.t(), atom(), term()) :: {term(), Revision.revision()}
  def get_with_revision(%Database{} = db, input_name, key) when is_atom(input_name) do
    case Memo.get(db, {:input, input_name, key}) do
      {:ok, %Entry{value: value, changed_at: changed_at}} -> {value, changed_at}
      :miss -> raise NotSetError, input_name: input_name, key: key
    end
  end

  @doc """
  Removes an input value and advances the revision counter.

  No-op if the key was not set. Uses `:ets.take/2` to atomically remove
  and detect existence in a single operation (no TOCTOU gap).

  Raises `ArgumentError` if the input is not registered.
  """
  @spec delete(Database.t(), atom(), term()) :: :ok
  def delete(%Database{memo_table: table} = db, input_name, key) when is_atom(input_name) do
    durability = lookup_durability!(db, input_name)
    query_key = {:input, input_name, key}

    case :ets.take(table, query_key) do
      [_ | _] ->
        new_rev = Revision.advance(db.revision, durability)
        Telemetry.input_delete(input_name, key, new_rev, durability)

      [] ->
        :ok
    end

    :ok
  end

  @doc """
  Lists all keys that have been set for an input.

  Returns an empty list if no keys have been set.
  """
  @spec keys(Database.t(), atom()) :: [term()]
  def keys(%Database{memo_table: table}, input_name) when is_atom(input_name) do
    # Match the 8-element ETS tuple with a 3-tuple key prefix.
    pattern = {{:input, input_name, :"$1"}, :_, :_, :_, :_, :_, :_, :_}

    table
    |> :ets.match(pattern)
    |> Enum.map(fn [k] -> k end)
  end

  # -- Private --

  defp lookup_durability!(%Database{input_registry: reg}, input_name) do
    case :ets.lookup(reg, input_name) do
      [{^input_name, opts}] -> Map.get(opts, :durability, :medium)
      [] -> raise ArgumentError, "input #{inspect(input_name)} is not registered"
    end
  end
end
