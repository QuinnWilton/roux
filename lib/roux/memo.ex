defmodule Roux.Memo do
  @moduledoc """
  Memo table: the cache layer that stores query results.

  Each entry records the computed value, when it changed, when it was last
  validated, and what dependencies were read during computation. This is the
  data structure that makes incrementality work.

  Entries are stored as flat tuples in ETS for efficiency and to support
  atomic partial updates via `:ets.select_replace/2`.

  ## Restored values stay encoded

  An entry restored from a manifest (`restore_persisted/2`) keeps its
  value in the external term format until something reads it: `get/2`,
  `entries/1` and `reduce_entries/3` decode it on the way out, and the
  value-free accessors never touch it. A warm run validates thousands of
  entries and reads the values of a handful, so decoding every value up
  front and copying it into ETS was most of the cost of restoring a
  manifest (on a 350-module scry project, 13 million words decoded and
  copied, of which a warm run that changed nothing reads about 15,000).
  The encoding also goes back out unchanged: `persisted/2` hands a
  still-encoded value to the next manifest without encoding it again.

  Nothing writes a decoded value back into the table. Doing that safely
  would need a compare-and-swap against a concurrent `put/3` of a newer
  entry for the same key, and a lost race would pair the newer entry's
  metadata with the older value. A process that reads a restored value
  more than once caches it itself (`Roux.Runtime` does, per revision).
  """

  alias Roux.Database
  alias Roux.Memo.Entry
  alias Roux.Revision

  @type query_key :: {query_name :: atom(), key :: term()} | {:input, atom(), term()}

  @typedoc """
  What an entry read: a query or input, an entity field, or the absence
  of an input (`{:input_absent, input_name, key}`, recorded by
  `Roux.Runtime.input/4` with a default).
  """
  @type dependency ::
          query_key()
          | {:entity_field, module(), term(), atom()}
          | {:input_absent, atom(), term()}

  @typedoc """
  An entry as a manifest persists it: every field of `Roux.Memo.Entry`,
  with the value in the external term format. See `persisted/2`.
  """
  @type persisted ::
          {query_key(), hash :: integer(), changed_at :: Revision.revision(),
           verified_at :: Revision.revision(), [dependency()], Revision.durability(),
           output_entities :: [{module(), term()}], encoded_value :: binary()}

  # -- ETS tuple layout --
  #
  # {query_key, value, hash, changed_at, verified_at, dependencies, durability, output_entities, encoded}
  #  pos 1      pos 2  pos 3 pos 4       pos 5        pos 6         pos 7       pos 8            pos 9
  #
  # `encoded` is nil when `value` holds the entry's value, and the value in
  # the external term format when the entry was restored and has not been
  # replaced since; `value` is then nil and means nothing. Only `put/3`
  # (nil) and `restore_persisted/2` (a binary) write position 9, each
  # together with position 2 in one insert; `put_unchanged/3` and
  # `update_verified` leave both alone. So the two never disagree.

  # Level 1 is a fifth of the default level's encode time for a fifth
  # more bytes. Against no compression, it takes twice as long to encode
  # and decodes as fast, and it keeps the manifest, and the memory an
  # undecoded value holds, a third of the size.
  @value_opts [{:compressed, 1}]

  @doc """
  Looks up a memo entry. Returns `{:ok, entry}` or `:miss`.
  """
  @spec get(Database.t(), query_key()) :: {:ok, Entry.t()} | :miss
  def get(%Database{memo_table: table}, key) do
    case :ets.lookup(table, key) do
      [tuple] -> {:ok, to_entry(tuple)}
      [] -> :miss
    end
  end

  @doc """
  Reads just the two fields dependency validation needs, without
  materializing the entry's value.

  Validation asks one question of each dependency — "did you change after I
  was verified, and how durable are you?" — and answering it through
  `get/2` copies the dependency's whole value out of ETS to read two
  integers.

  That is not the cheap operation it looks like. ETS copies terms on read;
  a large binary is refcounted and so escapes with a pointer copy, but a
  memoized *structure* does not. Fact rows — lists of lists of short
  binaries, which is what most of planchette's memo values are — get deep
  copied in full. Measured at **747×** the cost of reading the two fields
  directly, and validating a dependency graph touches every dependency of
  every node, so it dominated the per-edit budget: a comment edit on a
  256-module project spent 2.5s validating entries it then discarded.

  Returns `{:ok, changed_at, durability}` or `:miss`.
  """
  @spec dep_state(Database.t(), query_key()) ::
          {:ok, Roux.Revision.revision(), Roux.Revision.durability()} | :miss
  def dep_state(%Database{memo_table: table}, key) do
    # changed_at is position 4, durability position 7 (see the layout above).
    # `lookup_element/4` returns the default rather than raising on a
    # missing key, so a concurrent delete between the two reads surfaces as
    # a miss instead of an exception.
    case :ets.lookup_element(table, key, 4, :missing) do
      :missing ->
        :miss

      changed_at ->
        case :ets.lookup_element(table, key, 7, :missing) do
          :missing -> :miss
          durability -> {:ok, changed_at, durability}
        end
    end
  end

  @doc """
  Reads an entry's `verified_at` and `durability` without its value.

  The first two questions validation asks of an entry — "have I already
  checked you this revision?" and "can I skip you on durability?" — and
  neither needs the value. See `dep_state/2` for why reading it anyway is
  expensive.

  Returns `{:ok, verified_at, durability}` or `:miss`.
  """
  @spec verification_state(Database.t(), query_key()) ::
          {:ok, Roux.Revision.revision(), Roux.Revision.durability()} | :miss
  def verification_state(%Database{memo_table: table}, key) do
    # verified_at is position 5, durability position 7.
    case :ets.lookup_element(table, key, 5, :missing) do
      :missing ->
        :miss

      verified_at ->
        case :ets.lookup_element(table, key, 7, :missing) do
          :missing -> :miss
          durability -> {:ok, verified_at, durability}
        end
    end
  end

  @doc """
  Reads what re-executing an entry needs from the entry it replaces — its
  hash, `changed_at` and output entities — without its value.

  The three fields are read one at a time, so a `put/3` racing the read
  can mix two entries' fields: read it where no other put of the key can
  happen (`Roux.Runtime` reads it while it holds the key's computation
  claim).

  Returns `{:ok, hash, changed_at, output_entities}` or `:miss`.
  """
  @spec prior_state(Database.t(), query_key()) ::
          {:ok, integer(), Revision.revision(), [{module(), term()}]} | :miss
  def prior_state(%Database{memo_table: table}, key) do
    # hash is position 3, changed_at position 4, output_entities position 8.
    with hash when hash != :missing <- :ets.lookup_element(table, key, 3, :missing),
         changed_at when changed_at != :missing <- :ets.lookup_element(table, key, 4, :missing),
         outputs when outputs != :missing <- :ets.lookup_element(table, key, 8, :missing) do
      {:ok, hash, changed_at, outputs}
    else
      :missing -> :miss
    end
  end

  @doc "Reads an entry's `changed_at` without its value."
  @spec changed_at(Database.t(), query_key()) :: {:ok, Roux.Revision.revision()} | :miss
  def changed_at(%Database{memo_table: table}, key) do
    case :ets.lookup_element(table, key, 4, :missing) do
      :missing -> :miss
      changed_at -> {:ok, changed_at}
    end
  end

  @doc "Reads an entry's `durability` without its value."
  @spec durability(Database.t(), query_key()) :: {:ok, Roux.Revision.durability()} | :miss
  def durability(%Database{memo_table: table}, key) do
    case :ets.lookup_element(table, key, 7, :missing) do
      :missing -> :miss
      durability -> {:ok, durability}
    end
  end

  @doc """
  Reads an entry's dependency list without its value.

  Only needed on the path that actually walks dependencies, which is why it
  is separate from `verification_state/2` rather than returned alongside.
  """
  @spec dependencies(Database.t(), query_key()) :: {:ok, [dependency()]} | :miss
  def dependencies(%Database{memo_table: table}, key) do
    # dependencies is position 6.
    case :ets.lookup_element(table, key, 6, :missing) do
      :missing -> :miss
      deps -> {:ok, deps}
    end
  end

  @doc """
  Stores a memo entry, overwriting any existing entry for this key.

  Called after successful query execution with the buffered result.
  """
  @spec put(Database.t(), query_key(), Entry.t()) :: :ok
  def put(%Database{memo_table: table}, key, %Entry{} = entry) do
    :ets.insert(table, to_tuple(key, entry))
    :ok
  end

  @doc """
  Stores `entry` over an entry whose value is equal to (`===`)
  `entry.value`, keeping the stored value.

  Re-execution that comes back to the value it had (early cutoff)
  rewrites everything about the entry but its value. Keeping the stored
  value saves copying the equal new one into the table and, for a value
  restored from a manifest and not yet replaced, keeps its encoding, so
  the next manifest does not encode it again. The caller vouches for the
  equality; nothing here compares the values.

  Behaves as `put/3` when there is no stored entry.
  """
  @spec put_unchanged(Database.t(), query_key(), Entry.t()) :: :ok
  def put_unchanged(%Database{memo_table: table} = db, key, %Entry{} = e) do
    # Positions 3 to 8; the value (2) and its encoding (9) stay.
    fields = [
      {3, e.hash},
      {4, e.changed_at},
      {5, e.verified_at},
      {6, e.dependencies},
      {7, e.durability},
      {8, e.output_entities}
    ]

    if :ets.update_element(table, key, fields), do: :ok, else: put(db, key, e)
  end

  @doc """
  Updates only the `verified_at` field of an existing entry.

  Called when validation determines the cached value is still valid (early
  cutoff). Uses `:ets.select_replace/2` for atomicity — the entry is never
  partially updated.

  A no-op if no entry exists for the given key.
  """
  @spec update_verified(Database.t(), query_key(), Roux.Revision.revision()) :: :ok
  def update_verified(%Database{memo_table: table}, key, revision) do
    # Atomically update only verified_at (position 5 in the ETS tuple).
    # No-op if no entry exists for this key.
    :ets.update_element(table, key, {5, revision})
    :ok
  end

  @doc """
  Updates `verified_at` and `durability` together.

  Durability is the minimum over an entry's transitive inputs, computed
  when the entry EXECUTES. Early cutoff means a dependent is frequently
  validated WITHOUT executing, so without refreshing it here an entry
  keeps whatever level it was first computed with — and then skips a
  change at a lower level, serving a stale value with no error. Validation
  already reads every dependency's entry, so the current minimum is in
  hand exactly where it needs to be written.
  """
  @spec update_verified(Database.t(), query_key(), non_neg_integer(), Revision.durability()) ::
          :ok
  def update_verified(%Database{memo_table: table}, key, revision, durability) do
    # verified_at is position 5, durability position 7.
    :ets.update_element(table, key, [{5, revision}, {7, durability}])
    :ok
  end

  @doc """
  Removes a memo entry. Called during GC. No-op if the key doesn't exist.
  """
  @spec delete(Database.t(), query_key()) :: :ok
  def delete(%Database{memo_table: table}, key) do
    :ets.delete(table, key)
    :ok
  end

  @doc """
  Clears all memo entries. Called on database reset.
  """
  @spec delete_all(Database.t()) :: :ok
  def delete_all(%Database{memo_table: table}) do
    :ets.delete_all_objects(table)
    :ok
  end

  @doc """
  Returns all memo entries with their keys.

  Returns `[{query_key, entry}]` rather than `[entry]` so that callers (e.g.
  GC) can identify entries for deletion without a second lookup. Every
  value is materialized, restored ones decoded.
  """
  @spec entries(Database.t()) :: [{query_key(), Entry.t()}]
  def entries(%Database{memo_table: table}) do
    table
    |> :ets.tab2list()
    |> Enum.map(&to_entry_pair/1)
  end

  @doc """
  Folds over every entry as `{query_key, entry}` without materializing
  the table as a list: each entry is copied out of ETS on its own turn
  (a restored value decoded) and is garbage once the reducer is done
  with it.
  """
  @spec reduce_entries(Database.t(), acc, ({query_key(), Entry.t()}, acc -> acc)) :: acc
        when acc: term()
  def reduce_entries(%Database{memo_table: table}, acc, fun) when is_function(fun, 2) do
    :ets.foldl(fn tuple, acc -> fun.(to_entry_pair(tuple), acc) end, acc, table)
  end

  @doc """
  The entries `keep?` accepts, in the form a manifest persists them.

  `keep?` receives each entry's key and durability, before its value is
  touched. A restored value that was never replaced goes out in the
  encoding it came in with; any other value is encoded here, one entry
  at a time.
  """
  @spec persisted(Database.t(), (query_key(), Revision.durability() -> boolean())) ::
          [persisted()]
  def persisted(%Database{memo_table: table}, keep?) when is_function(keep?, 2) do
    :ets.foldl(
      fn {key, value, hash, changed_at, verified_at, deps, durability, outputs, encoded}, acc ->
        if keep?.(key, durability) do
          encoded = if is_binary(encoded), do: encoded, else: encode_value(value)
          [{key, hash, changed_at, verified_at, deps, durability, outputs, encoded} | acc]
        else
          acc
        end
      end,
      [],
      table
    )
  end

  @doc """
  Inserts persisted entries (`persisted/2`) with their values still
  encoded: each is decoded by the first read that needs it.

  Used by manifest restore. Overwrites entries with the same keys.
  Raises `ArgumentError` for anything that is not a persisted entry.
  """
  @spec restore_persisted(Database.t(), [persisted()]) :: :ok
  def restore_persisted(%Database{memo_table: table}, entries) when is_list(entries) do
    rows =
      Enum.map(entries, fn
        {key, hash, changed_at, verified_at, deps, durability, outputs, encoded}
        when is_binary(encoded) ->
          {key, nil, hash, changed_at, verified_at, deps, durability, outputs, encoded}

        other ->
          raise ArgumentError, "not a persisted memo entry: #{inspect(other, limit: 5)}"
      end)

    :ets.insert(table, rows)
    :ok
  end

  @doc """
  Decodes a persisted entry (`persisted/2`) into `{query_key, entry}`,
  for inspecting a manifest without restoring it.
  """
  @spec decode_persisted(persisted()) :: {query_key(), Entry.t()}
  def decode_persisted({key, hash, changed_at, verified_at, deps, durability, outputs, encoded})
      when is_binary(encoded) do
    to_entry_pair({key, nil, hash, changed_at, verified_at, deps, durability, outputs, encoded})
  end

  # -- Private helpers --

  defp to_tuple(key, %Entry{} = e) do
    {key, e.value, e.hash, e.changed_at, e.verified_at, e.dependencies, e.durability,
     e.output_entities, nil}
  end

  defp to_entry_pair(tuple), do: {elem(tuple, 0), to_entry(tuple)}

  defp to_entry(
         {_key, value, hash, changed_at, verified_at, deps, durability, output_entities, encoded}
       ) do
    %Entry{
      value: if(is_binary(encoded), do: decode_value(encoded), else: value),
      hash: hash,
      changed_at: changed_at,
      verified_at: verified_at,
      dependencies: deps,
      durability: durability,
      output_entities: output_entities
    }
  end

  defp encode_value(value), do: :erlang.term_to_binary(value, @value_opts)

  defp decode_value(encoded), do: :erlang.binary_to_term(encoded)
end
