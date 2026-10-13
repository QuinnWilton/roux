defmodule Roux.QueryFunIsolationTest do
  # Validation re-executes a stale dependency with the function this
  # process last ran under its name. Two databases in one process (two
  # roux-based Mix compilers, say) may register different queries under
  # one name; each must validate with its own.
  use ExUnit.Case, async: true

  alias Roux.{Database, Input, Lang, Runtime}

  defmodule Outer do
    use Roux.Query
    definput(:n)

    defquery :outer, key: k do
      {:outer, Roux.Runtime.query(db, :inner, k)}
    end

    defquery :inner, key: k do
      Roux.Runtime.input(db, :n, k) * 2
    end
  end

  defmodule SameName do
    use Roux.Query
    definput(:n)

    defquery :inner, key: k do
      Roux.Runtime.input(db, :n, k) * 100
    end
  end

  defmodule ReadsItsOwn do
    use Roux.Query
    definput(:n)

    defquery :inner, key: k do
      Roux.Runtime.query(db, :only_here, k)
    end

    defquery :only_here, key: k do
      Roux.Runtime.input(db, :n, k)
    end
  end

  defp open(module) do
    db = database()
    Lang.register_module(db, module)
    db
  end

  defp database do
    db = Database.new()

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    db
  end

  # Computes :outer at n = 1, runs `other`'s :inner in this process in its
  # own database, then sets n = 5, leaving :inner stale for :outer's
  # validation to re-execute.
  defp stale_after(other) do
    db = open(Outer)
    :ok = Input.set(db, :n, :k, 1)
    assert Runtime.query(db, :outer, :k) == {:outer, 2}

    second = open(other)
    :ok = Input.set(second, :n, :k, 1)
    _ = Runtime.query(second, :inner, :k)

    :ok = Input.set(db, :n, :k, 5)
    {db, second}
  end

  test "validation runs this database's function, not another's of the same name" do
    {db, _second} = stale_after(SameName)
    assert Runtime.query(db, :outer, :k) == {:outer, 10}
  end

  test "validation never asks for a query only the other database registers" do
    {db, _second} = stale_after(ReadsItsOwn)
    assert Runtime.query(db, :outer, :k) == {:outer, 10}
  end

  test "drop_cached_values/1 forgets one database's functions and keeps the other's" do
    {db, second} = stale_after(SameName)
    assert :ok = Runtime.drop_cached_values(second)

    cached = fn %Database{memo_table: table} ->
      Enum.any?(Process.get(), &match?({{Runtime, :query_fun, ^table, _}, _}, &1))
    end

    refute cached.(second)
    assert cached.(db)

    assert Runtime.query(db, :outer, :k) == {:outer, 10}
  end

  test "a stale query with no function to re-execute is an error that says so" do
    db = database()
    Input.register(db, Input.define(:source))
    Database.register_query(db, :leaf, %{code_version: "v1"})
    leaf = fn db, _ -> Runtime.input(db, :source, :all) end
    root = fn db, key -> Runtime.execute(db, :leaf, key, leaf) end

    :ok = Input.set(db, :source, :all, 1)
    assert Runtime.execute(db, :root, :k, root) == 1
    :ok = Runtime.drop_cached_values(db)
    :ok = Input.set(db, :source, :all, 2)

    assert_raise ArgumentError, ~r/:leaf is stale .* registered without a module/, fn ->
      Runtime.execute(db, :root, :k, root)
    end
  end
end
