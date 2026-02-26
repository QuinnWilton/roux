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

  @type query_key :: {query_name :: atom(), key :: term()} | {:input, atom(), term()}

  @type dependency :: query_key()

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
    # Body uses {:const, key} because tuple keys would otherwise be
    # interpreted as match spec function calls. The head is fine — tuples
    # in the head are literal patterns.
    match_spec = [
      {
        {key, :"$2", :"$3", :"$4", :_, :"$6", :"$7", :"$8"},
        [],
        [{{{:const, key}, :"$2", :"$3", :"$4", revision, :"$6", :"$7", :"$8"}}]
      }
    ]

    :ets.select_replace(table, match_spec)
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
