defmodule Roux.SessionTest do
  use ExUnit.Case, async: true

  alias Roux.{Blob, Input, Memo, QueryLog, Session}
  alias Roux.Test.PersistQueries

  @moduletag :tmp_dir

  defp open(tmp, opts \\ []) do
    Session.open(
      [
        modules: [PersistQueries],
        manifest: Path.join(tmp, "state/graph.manifest"),
        blob: Path.join(tmp, "store")
      ] ++ opts
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

  test "a session without a manifest keeps nothing; a temporary store goes on close" do
    store = Blob.temporary()
    session = Session.open(modules: [PersistQueries], blob: store)
    run(session, %{"a" => 1})
    assert {:unchanged, _} = Session.commit(session, %{})
    Session.close(session)
    refute File.exists?(store.root)
  end
end
