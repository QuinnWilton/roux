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

  ## Restored tables load on first use

  A table restored from an encoded snapshot (`encode_snapshot/1`) keeps
  its rows encoded until an operation misses: the first `intern/2`,
  `lookup/2` or `resolve/2` that does not find its answer loads them, then
  looks again. A warm run of a large scry project restores 170,000
  interned symbols and reads none of them; loading both tables eagerly was
  a quarter of restoring its manifest. See `restore/2` for why a miss is
  the right trigger, and why concurrent loads are safe.
  """

  @type id :: pos_integer()

  @type t :: %__MODULE__{
          forward: :ets.tid(),
          reverse: :ets.tid(),
          counter: :atomics.atomics_ref()
        }

  @enforce_keys [:forward, :reverse, :counter]
  defstruct [:forward, :reverse, :counter]

  # The reverse-table key under which a table restored from an encoded
  # snapshot keeps it: IDs start at 1, so no interned value has it. It
  # holds `{:pending, encoded, counter}` until the rows are loaded and
  # `{:loaded, encoded, counter}` after, so that a table nothing was
  # interned into since hands the next manifest the same encoding.
  @restored 0

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
        load_pending(table)

        case :ets.lookup(table.forward, value) do
          [{^value, id}] -> id
          [] -> intern_new(table, value)
        end
    end
  end

  # Allocates an ID for a value the forward table does not hold. Only
  # called once no restored rows are pending, so the value is not one of
  # them.
  defp intern_new(%__MODULE__{} = table, value) do
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

  @doc """
  Resolves an integer ID back to its original value.

  Returns `{:ok, value}` if the ID exists, `:error` otherwise.
  """
  @spec resolve(t(), id()) :: {:ok, term()} | :error
  def resolve(%__MODULE__{} = table, id) when is_integer(id) and id > 0 do
    case :ets.lookup(table.reverse, id) do
      [{^id, value}] ->
        {:ok, value}

      [] ->
        load_pending(table)

        case :ets.lookup(table.reverse, id) do
          [{^id, value}] -> {:ok, value}
          [] -> :error
        end
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
      [{^value, id}] ->
        {:ok, id}

      [] ->
        load_pending(table)

        case :ets.lookup(table.forward, value) do
          [{^value, id}] -> {:ok, id}
          [] -> :error
        end
    end
  end

  @doc """
  Returns the number of interned values.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = table) do
    load_pending(table)
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
    load_pending(table)
    # The rows before the counter: every ID in them was allocated before
    # the counter is read, so a concurrent intern cannot leave the
    # snapshot holding an ID above its counter.
    forward = :ets.tab2list(table.forward)
    %{version: @snapshot_version, forward: forward, counter: :atomics.get(table.counter, 1)}
  end

  @encoded_version 3

  @typedoc """
  A persisted intern table with its forward rows in the external term
  format, tagged with its own version. `restore/2` keeps the rows encoded
  until the table is first used.
  """
  @type encoded_snapshot :: %{
          version: 3,
          forward: binary(),
          counter: non_neg_integer()
        }

  @doc """
  Captures the forward table, encoded, and the counter: the snapshot a
  manifest persists.

  A table restored from an encoded snapshot that nothing has been
  interned into since hands back the encoding it was restored from,
  whether or not it has been read: its rows are exactly the restored ones.
  Once a value is interned, the restored encoding is dropped and the
  table is encoded as it stands.
  """
  @spec encode_snapshot(t()) :: encoded_snapshot()
  def encode_snapshot(%__MODULE__{} = table) do
    # The counter before the restored encoding: every new value takes an
    # ID before its row appears, so a counter still at the restored one
    # means no row has been added. A row added after this read is simply
    # not in this snapshot, and its ID is past the snapshot's counter.
    counter = :atomics.get(table.counter, 1)

    case :ets.lookup(table.reverse, @restored) do
      [{@restored, {_state, encoded, ^counter}}] ->
        %{version: @encoded_version, forward: encoded, counter: counter}

      [{@restored, {:loaded, _encoded, _restored_counter}}] ->
        # The counter has moved and never comes back: the encoding is of
        # no further use.
        :ets.delete(table.reverse, @restored)
        encode_rows(table)

      _pending_or_never_restored ->
        encode_rows(table)
    end
  end

  # The table as it stands. The counter after the rows, as in
  # `snapshot/1`: read before them, it could miss the ID of a row a
  # concurrent intern adds in between, and a table restored from the
  # snapshot would hand that ID out again.
  defp encode_rows(%__MODULE__{} = table) do
    load_pending(table)
    forward = :erlang.term_to_binary(:ets.tab2list(table.forward))
    %{version: @encoded_version, forward: forward, counter: :atomics.get(table.counter, 1)}
  end

  @doc """
  Restores a table from a snapshot: one produced by `snapshot/1`, or an
  encoded one produced by `encode_snapshot/1`.

  A `snapshot/1` snapshot fills both tables now, rebuilding the reverse
  table from the forward rows. An encoded snapshot sets the counter now
  and leaves the rows encoded, pending, until an operation misses (see
  "Restored tables load on first use"). A miss is the right trigger
  because nothing can be found before the rows are loaded, and nothing
  can be interned anew before a miss has loaded them: after a miss, an
  operation makes sure no rows are pending (loading them if they are)
  and only then looks again, and that second answer is final. A new
  value therefore takes its ID after every restored row is in place, so
  it never duplicates a restored value. Processes that miss at the same
  time each load the rows; the rows they insert are identical, and no
  restored row is ever rewritten afterwards (IDs past the restored
  counter belong to new values), so a second load changes nothing.

  Until the rows are loaded they sit in the reverse table under ID 0,
  which no interned value has (IDs start at 1), and the encoding stays
  there after (see `encode_snapshot/1`). Read a restored table through
  this module: its ETS tables are empty until it is used.

  Used during manifest loading. The caller must ensure the tables are empty
  or freshly created. Raises `ArgumentError` for a snapshot in any other
  format (such as the unversioned format that stored both tables).
  """
  @spec restore(t(), snapshot() | encoded_snapshot()) :: :ok
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

  def restore(%__MODULE__{} = table, %{
        version: @encoded_version,
        forward: forward,
        counter: counter
      })
      when is_binary(forward) and is_integer(counter) and counter >= 0 do
    :ets.insert(table.reverse, {@restored, {:pending, forward, counter}})
    :atomics.put(table.counter, 1, counter)
    :ok
  end

  def restore(%__MODULE__{}, snapshot) do
    raise ArgumentError,
          "unsupported Roux.Intern snapshot: expected version #{@snapshot_version} " <>
            "(%{version: #{@snapshot_version}, forward: rows, counter: n}) or " <>
            "#{@encoded_version} (%{version: #{@encoded_version}, forward: encoded rows, " <>
            "counter: n}), got: " <> inspect(snapshot, limit: 5)
  end

  # Loads the rows an encoded snapshot left pending, if they still are.
  # On return every restored row is in both tables, so a miss is only an
  # answer when the lookup that saw it comes after this: a lookup made
  # before it can have missed a row that another process's load inserted
  # a moment later, and then finding no rows pending proves nothing about
  # that lookup. See `restore/2` for why a concurrent load is harmless.
  defp load_pending(%__MODULE__{forward: forward, reverse: reverse}) do
    case :ets.lookup(reverse, @restored) do
      [{@restored, {:pending, encoded, counter}}] ->
        rows = :erlang.binary_to_term(encoded)
        :ets.insert(forward, rows)
        :ets.insert(reverse, Enum.map(rows, fn {value, id} -> {id, value} end))
        # Last: until the rows are all in, a process that misses loads
        # them itself rather than trusting a half-filled table.
        :ets.insert(reverse, {@restored, {:loaded, encoded, counter}})
        :ok

      _loaded_or_never_restored ->
        :ok
    end
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
