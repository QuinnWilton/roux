defmodule Roux.Blob.RacesTest do
  @moduledoc """
  What a store's readers, writers and collectors do when another process
  acts between their steps. Each race is held open in a VM of its own by
  `Roux.Test.RawGate`, on the hook every raw file operation of the store
  calls (`Roux.Blob.IO`): it acts at the step a race needs, so the
  interleaving happens on every run.
  """

  use ExUnit.Case, async: true

  alias Roux.Blob
  alias Roux.Blob.Trace
  alias Roux.Test.RawGate

  @moduletag :tmp_dir

  @day 24 * 60 * 60

  # A VM of this one's code, whose store operations a test may gate.
  defp peer! do
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})
    :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])
    on_exit(fn -> quietly(fn -> :peer.stop(peer) end) end)
    peer
  end

  # A peer the test already stopped, or a gate already taken down, is no
  # failure of the test.
  defp quietly(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  # `mfa` run in `peer` with `gates` on its store operations: what it
  # returned, and each gate's action's result.
  defp gated(peer, gates, {module, function, args}) do
    :ok = :peer.call(peer, RawGate, :install, [gates])

    try do
      {:peer.call(peer, module, function, args, 60_000),
       :peer.call(peer, RawGate, :uninstall, [])}
    after
      quietly(fn -> :peer.call(peer, RawGate, :uninstall, []) end)
    end
  end

  defp store!(tmp), do: Blob.open!(Path.join(tmp, "store"))

  # An entry nothing retains, written two days ago: a collection's to
  # take.
  defp old_entry!(store, bytes) do
    {:ok, digest} = Blob.put(store, bytes)
    path = Blob.path(store, digest)
    File.touch!(path, System.os_time(:second) - 2 * @day)
    {digest, path}
  end

  describe "a lookup" do
    test "never makes the action-cache entry a collection takes as it looks", %{tmp_dir: tmp} do
      store = store!(tmp)
      :ok = Blob.remember(store, :key, :value)
      [path] = Path.wildcard(Path.join([store.root, "ac", "*", "*"]))
      # Used longer ago than the store's refresh interval: a hit touches it.
      File.touch!(path, System.os_time(:second) - 2 * @day)

      # The entry goes right after the lookup read it, before its touch.
      gate = %{name: :gc, ops: [:read_file], path: path, action: {File, :rm, [path]}}
      {recalled, %{gc: :ok}} = gated(peer!(), [gate], {Blob, :recall, [store, :key]})

      assert recalled == {:ok, :value}
      assert File.lstat(path) == {:error, :enoent}
      assert Blob.recall(store, :key) == :miss
    end

    test "reads an entry whole or misses it, whatever a collection does meanwhile",
         %{tmp_dir: tmp} do
      store = store!(tmp)
      {digest, path} = old_entry!(store, :binary.copy("x", 100_000))

      gate = %{name: :gc, ops: [:read_file], path: path, action: {Blob, :gc, [store]}}
      {got, %{gc: %{removed: 1}}} = gated(peer!(), [gate], {Blob, :get, [store, digest]})

      # The read had the file open when the collection took the name.
      assert got == {:ok, :binary.copy("x", 100_000)}
      assert Blob.get(store, digest) == :miss
    end
  end

  describe "a trace lookup" do
    # A trace last used two hours ago (longer than the store's refresh
    # interval: a hit touches it), and its file.
    defp old_trace!(store, name, n) do
      :ok = Trace.put(store, name, [{n, n}], {:value, n})
      path = Path.join([store.root, "traces", Blob.term_digest(name), Blob.term_digest([{n, n}])])
      File.touch!(path, System.os_time(:second) - 2 * 60 * 60)
      path
    end

    # Another put under the name, keeping one trace: it removes the old.
    defp pruning_put(store, name),
      do: {Trace, :put, [store, name, [{2, 2}], {:value, 2}, [keep: 1]]}

    defp lookup(store, name),
      do: {Trace, :find, [store, name, &Function.identity/1, [limit: 8]]}

    test "misses a trace a put prunes between its listing and its read", %{tmp_dir: tmp} do
      store = store!(tmp)
      path = old_trace!(store, :raced, 1)

      # Pruned the moment the lookup has stat'ed it, before it reads it.
      gate = %{name: :put, ops: [:read_file_info], path: path, action: pruning_put(store, :raced)}
      {found, %{put: :ok}} = gated(peer!(), [gate], lookup(store, :raced))

      assert found == :miss
      refute File.exists?(path)
      assert [%{value: {:value, 2}}] = Trace.fetch(store, :raced)
    end

    test "hits a trace a put prunes after its read, and touches nothing back", %{tmp_dir: tmp} do
      store = store!(tmp)
      path = old_trace!(store, :raced, 1)

      # Pruned the moment its bytes are read: the lookup has them, and
      # its touch finds the file gone.
      gate = %{name: :put, ops: [:read_file], path: path, action: pruning_put(store, :raced)}
      {found, %{put: :ok}} = gated(peer!(), [gate], lookup(store, :raced))

      assert found == {:ok, {:value, 1}}
      refute File.exists?(path)
      assert [%{value: {:value, 2}}] = Trace.fetch(store, :raced)
    end
  end

  describe "a collection" do
    test "keeps an entry a writer touched after it was found old", %{tmp_dir: tmp} do
      store = store!(tmp)
      {digest, path} = old_entry!(store, "written again")

      # The collection's first look at the entry, then a writer of the
      # same bytes, which touches it.
      writer = %{
        name: :writer,
        ops: [:read_link_info],
        path: path,
        action: {Blob, :put, [store, "written again"]}
      }

      {stats, %{writer: {:ok, ^digest}}} = gated(peer!(), [writer], {Blob, :gc, [store]})

      assert stats.removed == 0
      assert {:ok, "written again"} = Blob.get(store, digest)
    end

    test "puts back an entry touched as it was being taken", %{tmp_dir: tmp} do
      store = store!(tmp)
      {digest, path} = old_entry!(store, "touched late")

      # Just before the rename aside: the touch lands on what is renamed.
      writer = %{
        name: :writer,
        ops: [:read_file_info],
        path: path,
        action: {Blob, :put, [store, "touched late"]}
      }

      {stats, %{writer: {:ok, ^digest}}} = gated(peer!(), [writer], {Blob, :gc, [store]})

      assert stats.removed == 0
      assert {:ok, "touched late"} = Blob.get(store, digest)
      assert Path.wildcard(Path.join([store.root, "trash", "*"])) == []
    end

    test "leaves the bytes a writer put again while the old copy was aside", %{tmp_dir: tmp} do
      store = store!(tmp)
      {digest, path} = old_entry!(store, "rewritten")

      # The moment the old copy leaves its name, a writer puts the same
      # bytes: it finds the name empty and writes a new entry there.
      writer = %{
        name: :writer,
        ops: [:rename],
        path: path,
        action: {Blob, :put, [store, "rewritten"]}
      }

      {_stats, %{writer: {:ok, ^digest}}} = gated(peer!(), [writer], {Blob, :gc, [store]})

      assert {:ok, "rewritten"} = Blob.get(store, digest)
    end

    test "takes an entry whole: a reader sees all of it or none of it", %{tmp_dir: tmp} do
      store = store!(tmp)
      bytes = :binary.copy("y", 100_000)
      {_digest, path} = old_entry!(store, bytes)

      reader = %{name: :reader, ops: [:rename], path: path, action: {File, :read, [path]}}
      {stats, %{reader: read}} = gated(peer!(), [reader], {Blob, :gc, [store]})

      assert stats.removed == 1
      assert read in [{:error, :enoent}, {:ok, bytes}]
    end
  end
end
