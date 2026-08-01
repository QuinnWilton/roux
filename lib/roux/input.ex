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

  `:durability` overrides the input definition's default FOR THIS KEY.
  Durability is otherwise a property of the whole input, which is too
  coarse for an editor: the file being typed in changes constantly while
  its neighbours do not, and one shared level means validation's
  durability check can never short-circuit. Marking the active buffer
  `:low` and leaving everything else `:medium` lets a keystroke advance
  only the low slot, so queries that do not read the edited file skip
  their dependency walk entirely.

  Raises `ArgumentError` if the input is not registered.
  """
  @spec set(Database.t(), atom(), term(), term(), keyword()) :: :ok
  def set(%Database{} = db, input_name, key, value, opts \\ []) when is_atom(input_name) do
    query_key = {:input, input_name, key}
    new_hash = :erlang.phash2(value)

    case Memo.get(db, query_key) do
      {:ok, %Entry{hash: old_hash, value: old_value}}
      when old_hash == new_hash and old_value == value ->
        :ok

      other ->
        durability =
          Keyword.get_lazy(opts, :durability, fn -> lookup_durability!(db, input_name) end)

        # When a key's durability CHANGES, advance at the level it USED to
        # have, not the new one. Readers recorded at the old level check
        # only that level and above; advancing solely at the new (lower)
        # one leaves them skipping validation and serving stale values.
        # Advancing at the old level invalidates them once, after which
        # they re-record the new level — validation refreshes it — and
        # subsequent writes are cheap again.
        advance_at =
          case other do
            {:ok, %Entry{durability: old}} when old != nil and old != durability -> old
            _ -> durability
          end

        new_rev = Revision.advance(db.revision, advance_at)

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
  Reads an input value, returning `{:ok, value}` or `:error`.

  Unlike `get/3`, does not raise when the key has not been set.
  """
  @spec fetch(Database.t(), atom(), term()) :: {:ok, term()} | :error
  def fetch(%Database{} = db, input_name, key) when is_atom(input_name) do
    case Memo.get(db, {:input, input_name, key}) do
      {:ok, %Entry{value: value}} -> {:ok, value}
      :miss -> :error
    end
  end

  @doc """
  Checks whether an input value has been set for the given key.
  """
  @spec exists?(Database.t(), atom(), term()) :: boolean()
  def exists?(%Database{} = db, input_name, key) when is_atom(input_name) do
    case Memo.get(db, {:input, input_name, key}) do
      {:ok, _} -> true
      :miss -> false
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
