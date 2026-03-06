# Concuerror test modules for Roux.Memo.
#
# Each module exercises a specific concurrent race condition with 2–3
# processes. Concuerror systematically explores all scheduler interleavings
# and verifies the assertions hold in every case.
#
# Run with:
#   mix concuerror -m Roux.Concurrency.MemoPutUpdateVerifiedRaceTest
#   mix concuerror --all

defmodule Roux.Concurrency.MemoPutUpdateVerifiedRaceTest do
  @moduledoc """
  One process overwrites an entry via put while another updates only
  verified_at via update_verified. The final entry must be well-formed —
  never a mix of fields from the old and new entries.
  """

  alias Roux.Memo
  alias Roux.Memo.Entry

  def test do
    db = make_db()
    key = {:query, :k}

    old_entry = %Entry{
      value: :old,
      hash: :erlang.phash2(:old),
      changed_at: 1,
      verified_at: 1,
      dependencies: [{:dep, :old}],
      durability: :low,
      output_entities: []
    }

    new_entry = %Entry{
      value: :new,
      hash: :erlang.phash2(:new),
      changed_at: 5,
      verified_at: 5,
      dependencies: [{:dep, :new}],
      durability: :medium,
      output_entities: []
    }

    Memo.put(db, key, old_entry)

    parent = self()

    spawn(fn ->
      Memo.put(db, key, new_entry)
      send(parent, :put_done)
    end)

    spawn(fn ->
      Memo.update_verified(db, key, 10)
      send(parent, :update_done)
    end)

    receive(do: (:put_done -> :ok))
    receive(do: (:update_done -> :ok))

    {:ok, final} = Memo.get(db, key)

    # The entry must be one of these well-formed states:
    # 1. old entry with verified_at bumped to 10 (update_verified, then put lost)
    #    — impossible, put always overwrites, so if put ran after update_verified
    #      the result is new_entry with verified_at 5.
    # 2. new entry with original verified_at (put ran last)
    # 3. new entry with verified_at bumped to 10 (put ran first, then update_verified)
    case {final.value, final.verified_at} do
      {:new, 5} -> :ok
      {:new, 10} -> :ok
      {:old, 10} -> :ok
    end

    :ets.delete(db.memo_table)
  end

  defp make_db do
    tid = :ets.new(:memo, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: tid,
      revision: Roux.Revision.new(),
      query_registry: tid,
      input_registry: tid,
      task_registry: tid,
      dedup_table: tid,
      intern_registry: tid,
      entity_registry: tid,
      table_owner: self(),
      supervisor: self()
    }
  end
end

defmodule Roux.Concurrency.MemoPutGetRaceTest do
  @moduledoc """
  One process overwrites an entry while another reads the same key.
  Get must return either the old entry or the new entry — never a
  partial tuple mixing fields from both.
  """

  alias Roux.Memo
  alias Roux.Memo.Entry

  def test do
    db = make_db()
    key = {:query, :k}

    old_entry = %Entry{
      value: :old,
      hash: :erlang.phash2(:old),
      changed_at: 1,
      verified_at: 1,
      dependencies: [],
      durability: :low,
      output_entities: []
    }

    new_entry = %Entry{
      value: :new,
      hash: :erlang.phash2(:new),
      changed_at: 2,
      verified_at: 2,
      dependencies: [{:dep, :a}],
      durability: :high,
      output_entities: []
    }

    Memo.put(db, key, old_entry)

    parent = self()

    spawn(fn ->
      Memo.put(db, key, new_entry)
      send(parent, :put_done)
    end)

    spawn(fn ->
      result = Memo.get(db, key)
      send(parent, {:get_result, result})
    end)

    receive(do: (:put_done -> :ok))

    result = receive(do: ({:get_result, r} -> r))

    case result do
      {:ok, ^old_entry} -> :ok
      {:ok, ^new_entry} -> :ok
    end

    :ets.delete(db.memo_table)
  end

  defp make_db do
    tid = :ets.new(:memo, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: tid,
      revision: Roux.Revision.new(),
      query_registry: tid,
      input_registry: tid,
      task_registry: tid,
      dedup_table: tid,
      intern_registry: tid,
      entity_registry: tid,
      table_owner: self(),
      supervisor: self()
    }
  end
end

defmodule Roux.Concurrency.MemoDeleteGetRaceTest do
  @moduledoc """
  One process deletes an entry while another reads the same key.
  Get must return either :miss or the full entry — never partial data.
  """

  alias Roux.Memo
  alias Roux.Memo.Entry

  def test do
    db = make_db()
    key = {:query, :k}

    entry = %Entry{
      value: :data,
      hash: :erlang.phash2(:data),
      changed_at: 1,
      verified_at: 1,
      dependencies: [{:dep, :x}],
      durability: :medium,
      output_entities: []
    }

    Memo.put(db, key, entry)

    parent = self()

    spawn(fn ->
      Memo.delete(db, key)
      send(parent, :delete_done)
    end)

    spawn(fn ->
      result = Memo.get(db, key)
      send(parent, {:get_result, result})
    end)

    receive(do: (:delete_done -> :ok))

    result = receive(do: ({:get_result, r} -> r))

    case result do
      :miss -> :ok
      {:ok, ^entry} -> :ok
    end

    :ets.delete(db.memo_table)
  end

  defp make_db do
    tid = :ets.new(:memo, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: tid,
      revision: Roux.Revision.new(),
      query_registry: tid,
      input_registry: tid,
      task_registry: tid,
      dedup_table: tid,
      intern_registry: tid,
      entity_registry: tid,
      table_owner: self(),
      supervisor: self()
    }
  end
end

defmodule Roux.Concurrency.MemoDoubleValidateTest do
  @moduledoc """
  Two processes call update_verified on the same key simultaneously with
  different revision values. The final verified_at must be one of the two
  values, and all other fields must be unchanged.
  """

  alias Roux.Memo
  alias Roux.Memo.Entry

  def test do
    db = make_db()
    key = {:query, :k}

    entry = %Entry{
      value: {:ast, :node},
      hash: :erlang.phash2({:ast, :node}),
      changed_at: 3,
      verified_at: 3,
      dependencies: [{:tokenize, "file.ex"}],
      durability: :low,
      output_entities: []
    }

    Memo.put(db, key, entry)

    parent = self()

    spawn(fn ->
      Memo.update_verified(db, key, 10)
      send(parent, :v1_done)
    end)

    spawn(fn ->
      Memo.update_verified(db, key, 20)
      send(parent, :v2_done)
    end)

    receive(do: (:v1_done -> :ok))
    receive(do: (:v2_done -> :ok))

    {:ok, final} = Memo.get(db, key)

    # verified_at must be one of the two update values.
    true = final.verified_at in [10, 20]

    # All other fields unchanged.
    ^entry = %Entry{final | verified_at: entry.verified_at}

    :ets.delete(db.memo_table)
  end

  defp make_db do
    tid = :ets.new(:memo, [:set, :public, read_concurrency: true])

    %Roux.Database{
      memo_table: tid,
      revision: Roux.Revision.new(),
      query_registry: tid,
      input_registry: tid,
      task_registry: tid,
      dedup_table: tid,
      intern_registry: tid,
      entity_registry: tid,
      table_owner: self(),
      supervisor: self()
    }
  end
end
