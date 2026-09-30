defmodule Roux.DependenciesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.{Database, Dependencies, Input, Memo, Revision, Runtime, Session}
  alias Roux.Test.PersistQueries

  setup do
    db = Database.new(reverse_dependencies: true)
    Input.register(db, Input.define(:source))

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    %{db: db}
  end

  defp read(db, key) do
    Runtime.execute(db, :read, key, fn db, key -> Runtime.input(db, :source, key, default: 0) end)
  end

  defp top(db, key) do
    Runtime.execute(db, :top, key, fn db, key -> 2 * read(db, key) end)
  end

  test "unrelated edits skip the graph and affected edits keep early cutoff", %{db: db} do
    Input.set(db, :source, :a, 1)
    assert top(db, :a) == 2
    Input.set(db, :source, :unrelated, 99)
    assert Dependencies.status(db, {:top, :a}) == :clean
    assert top(db, :a) == 2
    Input.set(db, :source, :a, 2)
    assert Dependencies.status(db, {:top, :a}) == :check
    assert top(db, :a) == 4
    assert Dependencies.status(db, {:top, :a}) == :clean
  end

  test "equal results still replace branch edges", %{db: db} do
    Input.set(db, :source, :branch, :a)
    Input.set(db, :source, :a, 1)
    Input.set(db, :source, :b, 1)
    branch = fn db, _ -> read(db, Runtime.input(db, :source, :branch)) end
    parent = fn db, _ -> Runtime.execute(db, :branch, :all, branch) end
    assert Runtime.execute(db, :parent, :all, parent) == 1
    {:ok, original_changed} = Memo.changed_at(db, {:parent, :all})
    Input.set(db, :source, :branch, :b)
    assert Runtime.execute(db, :parent, :all, parent) == 1
    assert Memo.changed_at(db, {:parent, :all}) == {:ok, original_changed}
    Input.set(db, :source, :a, 3)
    assert Dependencies.status(db, {:parent, :all}) == :clean
    Input.set(db, :source, :b, 4)
    assert Runtime.execute(db, :parent, :all, parent) == 4
  end

  test "absent inputs share their invalidation key with present and deleted inputs", %{db: db} do
    assert top(db, :optional) == 0
    Input.set(db, :source, :optional, 4)
    assert top(db, :optional) == 8
    Input.delete(db, :source, :optional)
    assert top(db, :optional) == 0
    Input.set(db, :source, :optional, 7)
    assert top(db, :optional) == 14
  end

  test "parallel dependencies dirty their readers", %{db: db} do
    Database.register_query(db, :p_read, %{module: __MODULE__, function: :p_read})
    for key <- [:a, :b], do: Input.set(db, :source, key, 1)
    sum = fn db, _ -> Runtime.parallel(db, [{:p_read, :a}, {:p_read, :b}]) |> Enum.sum() end
    assert Runtime.execute(db, :sum, :all, sum) == 2
    Input.set(db, :source, :b, 2)
    assert Runtime.execute(db, :sum, :all, sum) == 3
  end

  @doc false
  def p_read(db, key),
    do: Runtime.execute(db, :p_read, key, fn db, key -> Runtime.input(db, :source, key) end)

  test "unaccounted revisions and manual memo replacement cannot certify a stale root", %{db: db} do
    Input.set(db, :source, :a, 1)
    assert top(db, :a) == 2
    Revision.advance(db.revision, :high)
    assert Dependencies.status(db, {:top, :a}) == :stale
    assert top(db, :a) == 2
    {:ok, input} = Memo.get(db, {:input, :source, :a})
    Memo.put(db, {:input, :source, :a}, %{input | value: 2, hash: :erlang.phash2(2)})
    assert top(db, :a) == 4
    Memo.delete(db, {:read, :a})
    assert top(db, :a) == 4
  end

  test "deep code changes invalidate an otherwise clean root", %{db: db} do
    Input.set(db, :source, :a, 1)
    Database.register_query(db, :read, %{code_version: "one"})
    assert top(db, :a) == 2
    Database.register_query(db, :read, %{code_version: "two"})
    assert Dependencies.status(db, {:top, :a}) == :stale
    assert top(db, :a) == 2
    assert Memo.code_version(db, {:read, :a}) == {:ok, "two"}
  end

  test "a dead mutation owner leaves conservative recoverable state", %{db: db} do
    Input.set(db, :source, :a, 1)
    assert top(db, :a) == 2
    parent = self()

    pid =
      spawn(fn ->
        Dependencies.mutate(db, {:input, :source, :a}, fn ->
          send(parent, :inside)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :inside
    assert Dependencies.snapshot(db) == nil
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert Dependencies.status(db, {:top, :a}) == :stale
    assert top(db, :a) == 2
    assert Dependencies.status(db, {:top, :a}) == :clean
  end

  test "a validation between revision advance and value publication stays unverified", %{db: db} do
    Input.set(db, :source, :a, 1)
    assert top(db, :a) == 2
    parent = self()

    pid =
      spawn(fn ->
        Dependencies.mutate(db, {:input, :source, :a}, fn ->
          revision = Dependencies.advance(db, :medium)
          {:ok, old} = Memo.get(db, {:input, :source, :a})
          send(parent, :advanced)

          receive do
            :publish -> :ok
          end

          Memo.put_input(db, {:input, :source, :a}, %{
            old
            | value: 2,
              hash: :erlang.phash2(2),
              changed_at: revision,
              verified_at: revision
          })
        end)

        send(parent, :published)
      end)

    assert_receive :advanced
    assert top(db, :a) == 2
    send(pid, :publish)
    assert_receive :published
    assert top(db, :a) == 4
  end

  test "a computation overlapping an edit does not publish a clean certificate", %{db: db} do
    Input.set(db, :source, :a, 1)
    parent = self()

    pid =
      spawn(fn ->
        Runtime.execute(db, :overlap, :all, fn db, _ ->
          value = Runtime.input(db, :source, :a)
          send(parent, :read)

          receive do
            :finish -> :ok
          end

          value
        end)

        send(parent, :finished)
      end)

    assert_receive :read
    Input.set(db, :source, :a, 2)
    send(pid, :finish)
    assert_receive :finished
    assert Dependencies.status(db, {:overlap, :all}) == :stale

    assert Runtime.execute(db, :overlap, :all, fn db, _ -> Runtime.input(db, :source, :a) end) ==
             2
  end

  test "memo incarnation prevents an old validator certifying a replacement", %{db: db} do
    Input.set(db, :source, :a, 1)
    assert top(db, :a) == 2
    generation = Memo.generation(db, {:top, :a})
    token = Dependencies.snapshot(db)
    {:ok, old} = Memo.get(db, {:top, :a})
    Memo.put(db, {:top, :a}, old)
    Dependencies.certify(db, {:top, :a}, generation, token)
    assert Dependencies.status(db, {:top, :a}) == :check
    assert top(db, :a) == 2
  end

  @tag :tmp_dir
  test "restore rebuilds edges and keeps undemanded dirty entries stale", %{tmp_dir: dir} do
    opts = [
      modules: [PersistQueries],
      blob: Path.join(dir, "store"),
      manifest: Path.join(dir, "manifest"),
      reverse_dependencies: true
    ]

    first = Session.open(opts)
    Input.set(first.db, :psrc, :a, 1)
    assert PersistQueries.p_top(first.db, :a) == {:top, {:read, {:ok, 1}}}
    Input.set(first.db, :psrc, :a, 2)
    Session.commit(first, %{})
    Session.close(first)
    second = Session.open(opts)

    try do
      assert PersistQueries.p_top(second.db, :a) == {:top, {:read, {:ok, 2}}}
      Input.set(second.db, :psrc, :unrelated, 9)
      assert Dependencies.status(second.db, {:p_top, :a}) == :clean
    after
      Session.close(second)
    end
  end

  property "edits, deletions and requests agree with fresh evaluation" do
    check all(
            operations <-
              list_of(
                {member_of([:set, :delete, :request]), member_of([:a, :b, :unrelated]),
                 integer(0..5)},
                max_length: 35
              ),
            max_runs: 75
          ) do
      db = Database.new(reverse_dependencies: true)
      Input.register(db, Input.define(:source))

      try do
        Enum.reduce(operations, %{}, fn {op, key, value}, inputs ->
          inputs =
            case op do
              :set ->
                Input.set(db, :source, key, value)
                Map.put(inputs, key, value)

              :delete ->
                Input.delete(db, :source, key)
                Map.delete(inputs, key)

              :request ->
                inputs
            end

          for wanted <- [:a, :b], do: assert(top(db, wanted) == 2 * Map.get(inputs, wanted, 0))
          inputs
        end)
      after
        Database.shutdown(db)
      end
    end
  end
end
