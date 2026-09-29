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
    # Taken between its read and its touch, the entry may name what the
    # collection taking it takes too: its value is not used.
    test "misses the action-cache entry a collection takes as it looks, and never makes it again",
         %{tmp_dir: tmp} do
      store = store!(tmp)
      :ok = Blob.remember(store, :key, :value)
      [path] = Path.wildcard(Path.join([store.root, "traces", "*", "*"]))
      # Used longer ago than the store's refresh interval: a hit touches it.
      File.touch!(path, System.os_time(:second) - 2 * @day)

      # The entry goes right after the lookup read it, before its touch.
      gate = %{name: :gc, ops: [:read_file], path: path, action: {File, :rm, [path]}}
      {recalled, %{gc: :ok}} = gated(peer!(), [gate], {Blob, :recall, [store, :key]})

      assert recalled == :miss
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
    # A trace last used three hours ago (longer than the store's refresh
    # interval: a hit touches it), and its file.
    defp old_trace!(store, name, n) do
      :ok = Trace.put(store, name, [{n, n}], {:value, n})
      dir = Path.join([store.root, "traces", Blob.term_digest(name)])
      [path] = Path.wildcard(Path.join(dir, Blob.term_digest([{n, n}]) <> ".*"))
      File.touch!(path, System.os_time(:second) - 3 * 60 * 60)
      path
    end

    # Another put under the name, keeping one trace: it removes the old.
    defp pruning_put(store, name),
      do: {Trace, :put, [store, name, [{2, 2}], {:value, 2}, [keep: 1]]}

    defp lookup(store, name),
      do: {Trace, :find, [store, name, &Function.identity/1, [limit: 8]]}

    # The lookup's observer holds for every trace: the one put in place
    # of the pruned one is a hit, once the lookup looks again.
    test "looks again for a trace a put prunes between its listing and its read",
         %{tmp_dir: tmp} do
      store = store!(tmp)
      path = old_trace!(store, :raced, 1)

      # Pruned the moment the lookup has stat'ed it, before it reads it.
      gate = %{name: :put, ops: [:read_file_info], path: path, action: pruning_put(store, :raced)}
      {found, %{put: :ok}} = gated(peer!(), [gate], lookup(store, :raced))

      assert found == {:ok, {:value, 2}}
      refute File.exists?(path)
      assert [%{value: {:value, 2}}] = Trace.fetch(store, :raced)
    end

    test "passes over a trace a put prunes after its read, and touches nothing back",
         %{tmp_dir: tmp} do
      store = store!(tmp)
      path = old_trace!(store, :raced, 1)

      # Pruned the moment its bytes are read: the lookup has them, but its
      # touch finds the file gone, and it looks again.
      gate = %{name: :put, ops: [:read_file], path: path, action: pruning_put(store, :raced)}
      {found, %{put: :ok}} = gated(peer!(), [gate], lookup(store, :raced))

      assert found == {:ok, {:value, 2}}
      refute File.exists?(path)
      assert [%{value: {:value, 2}}] = Trace.fetch(store, :raced)
    end

    # A trace unused for longer than the collection's keep period, naming
    # a segment as old: a lookup that marks it used as the collection
    # looks at it keeps it, and the segment it names.
    test "a trace used as a collection looks at it keeps what it names", %{tmp_dir: tmp} do
      store = store!(tmp)
      {segment, segment_path} = old_entry!(store, "rows")
      :ok = Trace.put(store, :stale, [], %{segment: segment}, keep: 1)
      [trace] = Path.wildcard(Path.join([store.root, "traces", Blob.term_digest(:stale), "*"]))
      File.touch!(trace, System.os_time(:second) - 8 * @day)
      File.touch!(segment_path, System.os_time(:second) - 8 * @day)

      # The collection has found the trace old; a lookup finds it and
      # marks it used before the collection takes it.
      reader = %{
        name: :reader,
        ops: [:read_link_info],
        path: trace,
        action: {Trace, :find, [store, :stale, &Function.identity/1]}
      }

      {_stats, %{reader: {:ok, %{segment: ^segment}}}} =
        gated(peer!(), [reader], {Blob, :gc, [store]})

      assert {:ok, %{segment: ^segment}} = Trace.find(store, :stale, &Function.identity/1)
      assert {:ok, "rows"} = Blob.get(store, segment)
    end

    test "misses a trace a collection takes after the lookup read it", %{tmp_dir: tmp} do
      store = store!(tmp)
      {segment, segment_path} = old_entry!(store, "rows")
      :ok = Trace.put(store, :stale, [], %{segment: segment}, keep: 1)
      [trace] = Path.wildcard(Path.join([store.root, "traces", Blob.term_digest(:stale), "*"]))
      File.touch!(trace, System.os_time(:second) - 8 * @day)
      File.touch!(segment_path, System.os_time(:second) - 8 * @day)

      # The collection runs whole between the lookup's read of the trace
      # and its touch: it takes the trace and the segment it names.
      gc = %{name: :gc, ops: [:read_file], path: trace, action: {Blob, :gc, [store]}}
      {found, %{gc: %{removed: 2}}} = gated(peer!(), [gc], lookup(store, :stale))

      assert found == :miss
      assert Blob.get(store, segment) == :miss
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

    test "a reader of an entry it holds aside still links and reads it", %{tmp_dir: tmp} do
      store = store!(tmp)
      {digest, path} = old_entry!(store, "aside for a moment")
      dest = Path.join(tmp, "in.facts")

      # The moment the entry is renamed aside, before the collection looks
      # at it again: a link and a read of it.
      reader = %{
        name: :reader,
        ops: [:rename],
        path: path,
        action: {Roux.Test.BlobStress, :link_and_get, [store, digest, dest]}
      }

      {_stats, %{reader: {linked, read}}} = gated(peer!(), [reader], {Blob, :gc, [store]})

      assert linked == :ok
      assert read == {:ok, "aside for a moment"}
      assert File.read!(dest) == "aside for a moment"
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
