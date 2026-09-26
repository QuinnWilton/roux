defmodule Roux.Test.GroupFixture do
  @moduledoc """
  A database holding a fan-out over `{:upper, "a"}`, `{:upper, "b"}` or
  both, as a run left it, and the input of `"a"` changed since: the
  group is stale. Written directly rather than computed, to keep the
  scenarios Concuerror explores short (`test/concurrency/group_test.ex`).
  """

  alias Roux.{Input, Memo, Runtime}
  alias Roux.Memo.Entry

  @doc "The fan-out's body: `{:upper, key}` for each of the keys it is keyed by."
  def fan_out(db, members),
    do: Runtime.parallel(db, Enum.map(members, &{:upper, &1}), max_concurrency: 2)

  @doc """
  A database whose fan-out over `members` (`"a"`, `"b"` or both), keyed
  by them, went stale when `"a"` changed.
  """
  def stale_fan_out(members \\ ["a", "b"]) do
    memo = :ets.new(:memo, [:set, :public, read_concurrency: true, write_concurrency: true])
    dedup = :ets.new(:dedup, [:set, :public, write_concurrency: true])
    waiters = :ets.new(:waiters, [:duplicate_bag, :public, write_concurrency: true])
    reg = :ets.new(:reg, [:set, :public, read_concurrency: true])

    :ets.insert(reg, {:source, %{durability: :low}})
    :ets.insert(reg, {:upper, %{module: Roux.Test.RuntimeTestQueries, function: :upper}})

    db = %Roux.Database{
      memo_table: memo,
      revision: Roux.Revision.new(),
      query_registry: reg,
      input_registry: reg,
      task_registry: reg,
      dedup_table: dedup,
      dedup_waiters: waiters,
      intern_registry: reg,
      entity_registry: reg,
      table_owner: self(),
      supervisor: self()
    }

    Input.set(db, :source, "a", "x")
    Input.set(db, :source, "b", "y")
    put(db, {:upper, "a"}, "X", [{:input, :source, "a"}])
    put(db, {:upper, "b"}, "Y", [{:input, :source, "b"}])
    keys = Enum.map(members, &{:upper, &1})
    values = Enum.map(members, &String.upcase(%{"a" => "x", "b" => "y"}[&1]))
    put(db, {:fan_out, members}, values, [{:parallel, 2, keys}])
    Input.set(db, :source, "a", "z")
    db
  end

  defp put(db, key, value, deps) do
    Memo.put(db, key, %Entry{
      value: value,
      hash: :erlang.phash2(value),
      changed_at: 2,
      verified_at: 2,
      dependencies: deps,
      durability: :low,
      output_entities: []
    })
  end

  @doc "Deletes the fixture's tables."
  def cleanup(db) do
    :ets.delete(db.memo_table)
    :ets.delete(db.dedup_table)
    :ets.delete(db.dedup_waiters)
    :ets.delete(db.input_registry)
  end
end
