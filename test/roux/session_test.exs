defmodule Roux.SessionTest do
  use ExUnit.Case, async: true

  alias Roux.{Blob, Dependencies, Input, Memo, QueryLog, Session}
  alias Roux.Lang.Manifest
  alias Roux.Test.PersistQueries

  @moduletag :tmp_dir

  defp open(tmp, opts \\ []) do
    Session.open(
      Keyword.merge(
        [
          modules: [PersistQueries],
          manifest: Path.join(tmp, "state/graph.manifest"),
          blob: Path.join(tmp, "store")
        ],
        opts
      )
    )
  end

  defp run(session, inputs) do
    Enum.each(inputs, fn {key, value} -> Input.set(session.db, :psrc, key, value) end)
    Enum.map(inputs, fn {key, _} -> PersistQueries.p_top(session.db, key) end)
  end

  test "a second run restores what the first committed", %{tmp_dir: tmp} do
    first = open(tmp)
    refute first.restored?
    run(first, %{"a" => 1})
    assert {:written, _} = Session.commit(first, %{"a.src" => :meta})
    Session.close(first)

    second = open(tmp)

    try do
      assert second.restored?
      assert second.sources == %{"a.src" => :meta}
      log = QueryLog.start(second.db)
      assert PersistQueries.p_top(second.db, "a") == {:top, {:read, {:ok, 1}}}
      assert QueryLog.executions(log, :p_top) == []
      QueryLog.stop(log)
    after
      Session.close(second)
    end
  end

  test "commits only what changed", %{tmp_dir: tmp} do
    first = open(tmp)
    run(first, %{"a" => 1})
    {:written, first} = Session.commit(first, %{})
    Session.close(first)

    manifest = Path.join(tmp, "state/graph.manifest")
    stamp = File.stat!(manifest).mtime

    # Nothing set, nothing computed: nothing written.
    second = open(tmp)
    assert PersistQueries.p_top(second.db, "a") == {:top, {:read, {:ok, 1}}}
    assert {:unchanged, second} = Session.commit(second, %{})

    # An input set is a change.
    Input.set(second.db, :psrc, "a", 2)
    assert {:written, second} = Session.commit(second, %{})

    # So is an entry computed with no input moving.
    assert PersistQueries.p_top(second.db, "a") == {:top, {:read, {:ok, 2}}}
    assert {:written, second} = Session.commit(second, %{})
    assert {:unchanged, second} = Session.commit(second, %{})

    # So is other sources' metadata.
    assert {:written, second} = Session.commit(second, %{"b.src" => :moved})
    assert {:unchanged, _} = Session.commit(second, %{"b.src" => :moved})
    assert File.stat!(manifest).mtime >= stamp
    Session.close(second)
  end

  # As if the last run had been another build's, whose :p_reader had
  # other code: its entries' code version then, as that run kept them.
  defp outdate!(tmp, query) do
    session = open(tmp)

    Memo.reduce_entries(session.db, :ok, fn
      {{^query, _key} = key, entry}, :ok ->
        Dependencies.mutate(session.db, key, fn ->
          Memo.publish(session.db, key, %{entry | code_version: "old"}, false, :restored)
        end)

        :ok

      _other, :ok ->
        :ok
    end)

    :ok = Manifest.write(session.db, session.sources, session.manifest)
    Session.close(session)
  end

  defp kept(tmp) do
    {:ok, data} = Manifest.load(Path.join(tmp, "state/graph.manifest"))
    data |> Manifest.memo_entries() |> Enum.map(&elem(&1, 0))
  end

  test "an entry a whole run left outdated is dropped, with its readers, and only once",
       %{tmp_dir: tmp} do
    first = open(tmp)
    run(first, %{"a" => 1, "b" => 2})
    {:written, _} = Session.commit(first, %{})
    Session.close(first)
    outdate!(tmp, :p_reader)

    # A run that demands "a" alone: "b"'s reader is never asked again.
    second = open(tmp)
    assert Enum.sort(second.outdated) == [{:p_reader, "a"}, {:p_reader, "b"}]
    assert PersistQueries.p_top(second.db, "a") == {:top, {:read, {:ok, 1}}}
    assert {:written, second} = Session.commit(second, %{})
    # A later commit of the same session drops it still, and writes for it once.
    assert {:unchanged, second} = Session.commit(second, %{})
    Input.set(second.db, :psrc, "a", 3)
    assert PersistQueries.p_top(second.db, "a") == {:top, {:read, {:ok, 3}}}
    assert {:written, _} = Session.commit(second, %{})
    Session.close(second)

    kept = kept(tmp)
    assert {:p_reader, "a"} in kept
    refute {:p_reader, "b"} in kept
    refute {:p_top, "b"} in kept
    assert {:p_fact, "b"} in kept

    # Nothing kept is outdated now: a run that changes nothing writes nothing.
    third = open(tmp)
    assert third.outdated == []
    assert PersistQueries.p_top(third.db, "a") == {:top, {:read, {:ok, 3}}}
    assert {:unchanged, _} = Session.commit(third, %{})
    Session.close(third)
  end

  test "a transient entry and its readers are asked again next run", %{tmp_dir: tmp} do
    first = open(tmp)
    run(first, %{"a" => :lost})
    Session.commit(first, %{})
    Session.close(first)

    second = open(tmp)

    try do
      assert Memo.get(second.db, {:p_top, "a"}) == :miss
      assert {:ok, _} = Memo.get(second.db, {:input, :psrc, "a"})
    after
      Session.close(second)
    end
  end

  test "a module compiled against another roux raises, and its database goes", %{tmp_dir: tmp} do
    {:links, before} = Process.info(self(), :links)

    assert_raise Roux.Query.FormatError, fn ->
      Session.open(
        modules: [PersistQueries, Roux.Test.StaleLang],
        manifest: Path.join(tmp, "state/graph.manifest")
      )
    end

    # The database's supervisor, linked to the caller, is stopped.
    assert Process.info(self(), :links) == {:links, before}
  end

  test "force starts cold, and still commits", %{tmp_dir: tmp} do
    first = open(tmp)
    run(first, %{"a" => 1})
    Session.commit(first, %{})
    Session.close(first)

    forced = open(tmp, force: true)
    refute forced.restored?
    assert Memo.get(forced.db, {:p_top, "a"}) == :miss
    run(forced, %{"a" => 3})
    assert {:written, _} = Session.commit(forced, %{})
    Session.close(forced)

    again = open(tmp)
    assert PersistQueries.p_top(again.db, "a") == {:top, {:read, {:ok, 3}}}
    Session.close(again)
  end

  test "keeps a small extra term beside the manifest", %{tmp_dir: tmp} do
    manifest = Path.join(tmp, "state/graph.manifest")
    assert Session.read_extra(manifest) == :error

    session = open(tmp)
    {_, session} = Session.commit(session, %{}, extra: [diagnostics: [:one]])
    assert Session.read_extra(manifest) == {:ok, [diagnostics: [:one]]}
    {_, _} = Session.commit(session, %{}, extra: [diagnostics: []])
    assert Session.read_extra(manifest) == {:ok, [diagnostics: []]}
    assert Session.files(manifest) == [manifest, manifest <> ".extra"]
    Session.close(session)
  end

  test "a :blob value lives in the store, retained by the manifest", %{tmp_dir: tmp} do
    session = open(tmp)
    Input.set(session.db, :psrc, "a", :big)
    PersistQueries.p_blob(session.db, "a")
    Session.commit(session, %{})
    store = session.blob
    Session.close(session)

    [root] = Path.wildcard(Path.join([store.root, "roots", "*"]))
    assert {:ok, {owner, [_digest]}} = Blob.decode(File.read!(root))
    assert owner == Path.join(tmp, "state/graph.manifest")
  end

  # Two builds sharing a store (an application renamed, its old ebin left
  # in `_build`): a value computed by the first build's code must not be
  # served once that code resolves to the second's, though every file of
  # the first is still there, unchanged.
  test "an entry computed by one build's code is recomputed once its code resolves to another's",
       %{tmp_dir: tmp} do
    n = System.unique_integer([:positive])
    leaf = Module.concat(Roux.SessionTest, "Leaf#{n}")
    queries = Module.concat(Roux.SessionTest, "BuildQueries#{n}")
    old = build!(Path.join(tmp, "old"), "defmodule #{inspect(leaf)}, do: def(v, do: :old)")
    new = build!(Path.join(tmp, "new"), "defmodule #{inspect(leaf)}, do: def(v, do: :new)")

    ebin =
      build!(Path.join(tmp, "queries"), """
      defmodule #{inspect(queries)} do
        # roux's own modules left out: a digest over beams `mix test` just
        # built keeps no trace.
        use Roux.Query, code: [exclude: [Roux.Query, Roux.Runtime], follow_excluded: false]
        @compile {:no_warn_undefined, #{inspect(leaf)}}

        defquery :leaf_value, key: key do
          #{inspect(leaf)}.v()
        end
      end
      """)

    on_exit(fn ->
      for dir <- [old, new, ebin], do: :code.del_path(String.to_charlist(dir))
      Enum.each([leaf, queries], &unload/1)
    end)

    run = fn ->
      session = open(tmp, modules: [queries])
      value = queries.leaf_value(session.db, :k)
      Session.commit(session, %{})
      Session.close(session)
      value
    end

    true = :code.add_patha(String.to_charlist(ebin))
    true = :code.add_patha(String.to_charlist(old))
    assert run.() == :old
    assert [_kept] = Path.wildcard(Path.join([tmp, "store", "traces", "*", "*"]))

    # The next run, as a fresh VM would make it: the module resolves to
    # the second build now.
    unload(leaf)
    :code.del_path(String.to_charlist(old))
    true = :code.add_patha(String.to_charlist(new))
    :ok = Roux.Code.forget()
    assert run.() == :new
  end

  # Compiles `source` into `dir/ebin`, the beams a minute old (a trace is
  # kept only over files that old), and unloads what it defined.
  defp build!(dir, source) do
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    past = System.os_time(:second) - 60

    for {module, beam} <- Code.compile_string(source, Path.join(dir, "source.ex")) do
      unload(module)
      path = Path.join(ebin, "#{module}.beam")
      File.write!(path, beam)
      File.touch!(path, past)
    end

    ebin
  end

  # Old code first: `:code.delete/1` keeps a module loaded while it has
  # old code (a second compile of its name leaves one).
  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  test "a session without a manifest keeps nothing; a temporary store goes on close" do
    store = Blob.temporary()
    session = Session.open(modules: [PersistQueries], blob: store)
    run(session, %{"a" => 1})
    assert {:unchanged, _} = Session.commit(session, %{})
    Session.close(session)
    refute File.exists?(store.root)
  end
end
