defmodule Roux.Intern do
  @moduledoc """
  Bidirectional mapping from values to unique integer IDs.

  Makes equality comparison O(1) for interned values, which directly
  impacts early cutoff performance. Every string, identifier, and type
  that flows through the query graph should be interned as early as
  possible.

  Interned values use integer IDs, never atoms, to avoid BEAM atom table
  exhaustion (see D10).

  ## Concurrency

  All operations are thread-safe. Concurrent calls to `intern/2` with the
  same value are resolved lock-free via `:atomics.add_get/3` for ID
  allocation and `:ets.insert_new/2` as a compare-and-swap. IDs need not
  be contiguous — the counter may advance past IDs that lost the CAS race.
  """

  @type id :: pos_integer()

  @type t :: %__MODULE__{
          forward: :ets.tid(),
          reverse: :ets.tid(),
          counter: :atomics.atomics_ref()
        }

  @enforce_keys [:forward, :reverse, :counter]
  defstruct [:forward, :reverse, :counter]

  @doc """
  Creates a new intern table pair.

  The `name` argument is for debugging and ETS introspection only — tables
  are unnamed to avoid atom exhaustion.
  """
  @spec new(atom()) :: t()
  def new(name) when is_atom(name) do
    forward = :ets.new(name, [:set, :public, read_concurrency: true])
    reverse = :ets.new(name, [:set, :public, read_concurrency: true])
    counter = :atomics.new(1, signed: false)

    %__MODULE__{forward: forward, reverse: reverse, counter: counter}
  end

  @doc """
  Interns a value, returning its integer ID.

  If the value is already interned, returns the existing ID. Thread-safe:
  concurrent calls with the same value return the same ID.
  """
  @spec intern(t(), term()) :: id()
  def intern(%__MODULE__{} = table, value) do
    case :ets.lookup(table.forward, value) do
      [{^value, id}] ->
        id

      [] ->
        id = :atomics.add_get(table.counter, 1, 1)

        # Insert reverse first so that resolve/2 is always consistent:
        # the moment a value appears in the forward table, its ID is
        # already resolvable.
        :ets.insert(table.reverse, {id, value})

        case :ets.insert_new(table.forward, {value, id}) do
          true ->
            id

          false ->
            # Another process interned this value first. Clean up our
            # orphaned reverse entry and return the winning ID.
            :ets.delete(table.reverse, id)
            [{^value, existing_id}] = :ets.lookup(table.forward, value)
            existing_id
        end
    end
  end

  @doc """
  Resolves an integer ID back to its original value.

  Returns `{:ok, value}` if the ID exists, `:error` otherwise.
  """
  @spec resolve(t(), id()) :: {:ok, term()} | :error
  def resolve(%__MODULE__{} = table, id) when is_integer(id) and id > 0 do
    case :ets.lookup(table.reverse, id) do
      [{^id, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc """
  Resolves an integer ID back to its original value.

  Raises `Roux.Intern.UnknownIdError` if the ID has not been interned.
  """
  @spec resolve!(t(), id()) :: term()
  def resolve!(%__MODULE__{} = table, id) when is_integer(id) and id > 0 do
    case resolve(table, id) do
      {:ok, value} -> value
      :error -> raise Roux.Intern.UnknownIdError, id: id
    end
  end

  @doc """
  Checks if a value is already interned without interning it.

  Returns `{:ok, id}` if the value is interned, `:error` otherwise.
  """
  @spec lookup(t(), term()) :: {:ok, id()} | :error
  def lookup(%__MODULE__{} = table, value) do
    case :ets.lookup(table.forward, value) do
      [{^value, id}] -> {:ok, id}
      [] -> :error
    end
  end

  @doc """
  Returns the number of interned values.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = table) do
    :ets.info(table.forward, :size)
  end

  @snapshot_version 2

  @typedoc """
  A persisted intern table: the forward rows and the ID counter, tagged
  with the snapshot format's version.

  Only one direction is stored. Every value appears in both tables, so
  persisting both stored each value twice — on a large scry project the
  interned symbols were a third of the manifest. The forward table is the
  one kept because it is authoritative: an ID only becomes live when its
  `{value, id}` row wins `:ets.insert_new/2`, while the reverse table can
  briefly hold the orphaned ID of a process that lost that race. The
  reverse table is rebuilt from it on restore.
  """
  @type snapshot :: %{
          version: 2,
          forward: [{term(), id()}],
          counter: non_neg_integer()
        }

  @doc """
  Captures the forward table and the counter for manifest persistence.

  The snapshot is versioned; `restore/2` refuses any other format rather
  than misreading it.
  """
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{} = table) do
    %{
      version: @snapshot_version,
      forward: :ets.tab2list(table.forward),
      counter: :atomics.get(table.counter, 1)
    }
  end

  @doc """
  Restores both tables and the counter from a snapshot produced by
  `snapshot/1`, rebuilding the reverse table from the forward rows.

  Used during manifest loading. The caller must ensure the tables are empty
  or freshly created. Raises `ArgumentError` for a snapshot in any other
  format (such as the unversioned format that stored both tables).
  """
  @spec restore(t(), snapshot()) :: :ok
  def restore(%__MODULE__{} = table, %{
        version: @snapshot_version,
        forward: forward,
        counter: counter
      })
      when is_list(forward) and is_integer(counter) and counter >= 0 do
    :ets.insert(table.forward, forward)
    :ets.insert(table.reverse, Enum.map(forward, fn {value, id} -> {id, value} end))
    :atomics.put(table.counter, 1, counter)
    :ok
  end

  def restore(%__MODULE__{}, snapshot) do
    raise ArgumentError,
          "unsupported Roux.Intern snapshot: expected version #{@snapshot_version} " <>
            "(%{version: #{@snapshot_version}, forward: rows, counter: n}), got: " <>
            inspect(snapshot, limit: 5)
  end

  @doc """
  Deletes both ETS tables. Called during database shutdown.
  """
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{} = table) do
    :ets.delete(table.forward)
    :ets.delete(table.reverse)
    :ok
  end
end
