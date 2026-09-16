defmodule Roux.Memo do
  @moduledoc """
  Memo table: the cache layer that stores query results.

  Each entry records the computed value, when it changed, when it was last
  validated, and what dependencies were read during computation. This is the
  data structure that makes incrementality work.

  Entries are stored as flat tuples in ETS for efficiency and to support
  atomic partial updates via `:ets.select_replace/2`.
  """

  alias Roux.Database
  alias Roux.Memo.Entry
  alias Roux.Revision

  @type query_key :: {query_name :: atom(), key :: term()} | {:input, atom(), term()}

  @type dependency :: query_key() | {:entity_field, module(), term(), atom()}

  # -- ETS tuple layout --
  #
  # {query_key, value, hash, changed_at, verified_at, dependencies, durability, output_entities}
  #  pos 1      pos 2  pos 3 pos 4       pos 5        pos 6         pos 7       pos 8

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
  GC) can identify entries for deletion without a second lookup.
  """
  @spec entries(Database.t()) :: [{query_key(), Entry.t()}]
  def entries(%Database{memo_table: table}) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn tuple -> {elem(tuple, 0), to_entry(tuple)} end)
  end

  @doc """
  Folds over every entry as `{query_key, entry}` without materializing
  the table as a list: each entry is copied out of ETS on its own turn
  and is garbage once the reducer is done with it.
  """
  @spec reduce_entries(Database.t(), acc, ({query_key(), Entry.t()}, acc -> acc)) :: acc
        when acc: term()
  def reduce_entries(%Database{memo_table: table}, acc, fun) when is_function(fun, 2) do
    :ets.foldl(fn tuple, acc -> fun.({elem(tuple, 0), to_entry(tuple)}, acc) end, acc, table)
  end

  # -- Private helpers --

  defp to_tuple(key, %Entry{} = e) do
    {key, e.value, e.hash, e.changed_at, e.verified_at, e.dependencies, e.durability,
     e.output_entities}
  end

  defp to_entry({_key, value, hash, changed_at, verified_at, deps, durability, output_entities}) do
    %Entry{
      value: value,
      hash: hash,
      changed_at: changed_at,
      verified_at: verified_at,
      dependencies: deps,
      durability: durability,
      output_entities: output_entities
    }
  end
end
