defmodule Roux.Lang.PackedManifestTest do
  use ExUnit.Case, async: true

  alias Roux.{Blob, Database, Input, Memo, Runtime}
  alias Roux.Lang.Manifest
  alias Roux.Memo.Value
  alias Roux.Test.PersistQueries

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    store = Blob.open!(Path.join(dir, "store"), refresh: 0)
    db = database(store)
    %{store: store, db: db, path: Path.join(dir, "manifest")}
  end

  test "distinct values share a pack and unchanged checkpoints preserve locations", ctx do
    seed(ctx.db, %{a: {:a, "one"}, b: {:b, "two"}, duplicate: {:a, "one"}})
    Manifest.write(ctx.db, %{}, ctx.path)
    first = handles(ctx.path)
    assert {:packed, logical, physical, offset, length} = first.a
    assert first.a == first.duplicate
    assert {:packed, _, ^physical, _, _} = first.b
    assert {:ok, bytes} = Blob.get_slice(ctx.store, physical, offset, length, logical)
    assert {:ok, {:a, "one"}} = Blob.decode(bytes)

    Manifest.write(ctx.db, %{}, ctx.path)
    assert handles(ctx.path) == first

    restored = restore(ctx.store, ctx.path)
    Manifest.write(restored, %{}, ctx.path)
    assert handles(ctx.path) == first
    assert {:a, "one"} = PersistQueries.p_blob(restored, :a)

    seed(ctx.db, %{new: {:new, "three"}})
    Manifest.write(ctx.db, %{}, ctx.path)
    assert Map.take(handles(ctx.path), [:a, :b, :duplicate]) == first
  end

  test "a damaged neighboring record does not force reading it", ctx do
    seed(ctx.db, %{a: "one", b: "two"})
    Manifest.write(ctx.db, %{}, ctx.path)
    %{a: a, b: {:packed, _, physical, offset, _}} = handles(ctx.path)
    pack_path = Blob.path(ctx.store, physical)
    bytes = File.read!(pack_path)
    <<prefix::binary-size(offset), byte, rest::binary>> = bytes
    File.chmod!(pack_path, 0o644)
    File.write!(pack_path, [prefix, Bitwise.bxor(byte, 1), rest])
    db = restore(ctx.store, ctx.path)

    assert "one" == PersistQueries.p_blob(db, :a)
    assert {:ok, _} = Value.load_bytes(ctx.store, a)
    log = Roux.QueryLog.start(db)
    assert "two" == PersistQueries.p_blob(db, :b)
    assert Roux.QueryLog.executions(log, :p_blob) == [:b]
    Roux.QueryLog.stop(log)
  end

  test "missing live receipts republish from cached bytes", ctx do
    seed(ctx.db, %{a: "one", b: "two"})
    Manifest.write(ctx.db, %{}, ctx.path)
    %{a: {:packed, _, physical, _, _}} = handles(ctx.path)
    File.rm!(Blob.path(ctx.store, physical))
    Manifest.write(ctx.db, %{}, ctx.path)
    assert {:ok, _} = Value.load_bytes(ctx.store, handles(ctx.path).a)
    db = restore(ctx.store, ctx.path)
    assert "one" == PersistQueries.p_blob(db, :a)
  end

  test "restored values relocate to an explicit target store", ctx do
    seed(ctx.db, %{a: "one", b: "two"})
    Manifest.write(ctx.db, %{}, ctx.path)
    old = handles(ctx.path)
    db = restore(ctx.store, ctx.path)
    other = Blob.open!(Path.join(ctx.tmp_dir, "other"))
    target = Path.join(ctx.tmp_dir, "other.manifest")
    Manifest.write(db, %{}, target, blob: other)
    copied = handles(target)

    for key <- [:a, :b] do
      assert Value.logical_digest(old[key]) == Value.logical_digest(copied[key])
      assert {:ok, _} = Value.load_bytes(other, copied[key])
    end

    File.rm_rf!(ctx.store.root)
    restored = restore(other, target)
    assert "one" == PersistQueries.p_blob(restored, :a)
    assert "two" == PersistQueries.p_blob(restored, :b)
  end

  test "an explicit nil store materializes restored values inline", ctx do
    seed(ctx.db, %{a: "one", b: "two"})
    Manifest.write(ctx.db, %{}, ctx.path)
    db = restore(ctx.store, ctx.path)
    target = Path.join(ctx.tmp_dir, "inline.manifest")
    Manifest.write(db, %{}, target, blob: nil)
    assert Enum.all?(Map.values(handles(target)), &is_binary/1)
    restored = restore(nil, target)
    assert "one" == PersistQueries.p_blob(restored, :a)
  end

  test "target-store relocation also copies ordinary blobs held by values", ctx do
    {:ok, digest} = Blob.put(ctx.store, "artifact bytes")
    Database.register_query(ctx.db, :holder, %{module: __MODULE__, function: :holder})

    Runtime.execute(ctx.db, :holder, :one, fn _, _ ->
      Runtime.hold(digest)
      {:artifact, digest}
    end)

    target = Blob.open!(Path.join(ctx.tmp_dir, "target"))
    Manifest.write(ctx.db, %{}, ctx.path, blob: target)
    assert {:ok, "artifact bytes"} = Blob.get(target, digest)
    age_all(target)
    Blob.gc(target, grace: 0, keep: 0)
    assert Blob.member?(target, digest)

    target_path = Blob.path(target, digest)
    File.chmod!(target_path, 0o644)
    File.write!(target_path, "damaged bytes!")
    Manifest.write(ctx.db, %{}, ctx.path, blob: target)
    assert {:ok, "artifact bytes"} = Blob.get(target, digest)

    File.rm!(Blob.path(ctx.store, digest))
    empty = Blob.open!(Path.join(ctx.tmp_dir, "empty"))
    Manifest.write(ctx.db, %{}, ctx.path, blob: empty)
    {:ok, data} = Manifest.load(ctx.path)
    refute Enum.any?(data.memo_entries, &(elem(&1, 0) == {:holder, :one}))
  end

  test "a lost restored value is omitted when saving without demanding it", ctx do
    seed(ctx.db, %{a: "one", b: "two"})
    Manifest.write(ctx.db, %{}, ctx.path)
    db = restore(ctx.store, ctx.path)
    for digest <- roots(handles(ctx.path)), do: File.rm!(Blob.path(ctx.store, digest))
    Manifest.write(db, %{}, ctx.path)
    assert handles(ctx.path) == %{}
    restored = restore(ctx.store, ctx.path)
    assert "one" == PersistQueries.p_blob(restored, :a)
  end

  test "sparse packs compact without changing logical identities or older manifests", ctx do
    seed(ctx.db, %{large: :crypto.strong_rand_bytes(800_000), small: "survivor"})
    Manifest.write(ctx.db, %{}, ctx.path)
    before = handles(ctx.path)
    assert {:packed, logical, old_pack, _, _} = before.small
    old_path = Path.join(ctx.tmp_dir, "old.manifest")
    Manifest.write(ctx.db, %{}, old_path)

    Memo.delete(ctx.db, {:p_blob, :large})
    assert "survivor" == PersistQueries.p_blob(ctx.db, :small)
    Manifest.write(ctx.db, %{}, ctx.path)
    after_handles = handles(ctx.path)
    assert Value.logical_digest(after_handles.small) == logical
    refute old_pack in Value.roots(after_handles.small)
    age_all(ctx.store)
    Blob.gc(ctx.store, grace: 0, keep: 0)
    assert {:ok, _} = Value.load_bytes(ctx.store, before.large)

    File.rm!(old_path)
    age_all(ctx.store)
    Blob.gc(ctx.store, grace: 0, keep: 0)
    refute Blob.member?(ctx.store, old_pack)
    assert {:ok, _} = Value.load_bytes(ctx.store, after_handles.small)
  end

  test "oversized values stay loose and ordinary artifacts remain independent", ctx do
    large = :crypto.strong_rand_bytes(1_100_000)
    seed(ctx.db, %{large: large, small: "one", other: "two"})
    {:ok, artifact} = Blob.put(ctx.store, "direct artifact")
    Manifest.write(ctx.db, %{}, ctx.path)
    assert {:blob, digest} = handles(ctx.path).large
    assert {:ok, ^large} = Blob.get_term(ctx.store, digest)
    assert {:packed, _, _, _, _} = handles(ctx.path).small
    assert {:ok, "direct artifact"} = Blob.get(ctx.store, artifact)
  end

  test "retention from an interleaved owner write causes recoverable misses", ctx do
    seed(ctx.db, %{a: "old-a", b: "old-b"})
    Manifest.write(ctx.db, %{}, ctx.path)
    old_roots = roots(handles(ctx.path))
    seed(ctx.db, %{a: "new-a", b: "new-b"})
    Manifest.write(ctx.db, %{}, ctx.path)
    # The older writer's final retain can run after the newer manifest's rename.
    Blob.retain(ctx.store, Path.expand(ctx.path), old_roots)
    age_all(ctx.store)
    Blob.gc(ctx.store, grace: 0, keep: 0)

    db = restore(ctx.store, ctx.path)
    log = Roux.QueryLog.start(db)
    assert "new-a" == PersistQueries.p_blob(db, :a)
    assert "new-b" == PersistQueries.p_blob(db, :b)
    assert Enum.sort(Roux.QueryLog.executions(log, :p_blob)) == [:a, :b]
    Roux.QueryLog.stop(log)
  end

  test "concurrent independent manifests publish complete shared packs", ctx do
    seed(ctx.db, %{a: "one", b: "two"})
    paths = for n <- 1..4, do: Path.join(ctx.tmp_dir, "manifest-#{n}")
    tasks = for path <- paths, do: Task.async(fn -> Manifest.write(ctx.db, %{}, path) end)
    for task <- tasks, do: assert(:ok = Task.await(task))

    for path <- paths do
      db = restore(ctx.store, path)
      assert "one" == PersistQueries.p_blob(db, :a)
      assert "two" == PersistQueries.p_blob(db, :b)
    end
  end

  test "invalid packed locations are refused before restoration", ctx do
    seed(ctx.db, %{a: "one", b: "two"})
    Manifest.write(ctx.db, %{}, ctx.path)
    {:ok, data} = Manifest.load(ctx.path)
    [entry | _] = data.memo_entries
    {:packed, logical, physical, offset, length} = handles(ctx.path).a

    for bad <- [
          {:packed, logical, physical, -1, length},
          {:packed, logical, physical, offset, 0},
          {:packed, "bad", physical, offset, length},
          {:packed, logical, physical, offset, 0x8000000000000000}
        ] do
      payload = :erlang.term_to_binary(%{data | memo_entries: [put_elem(entry, 7, bad)]})
      File.write!(ctx.path, ["ROUXMNFT", <<7::32, :erlang.crc32(payload)::32>>, payload])
      assert :error = Manifest.load(ctx.path)
    end
  end

  test "legacy loose values load and keep their locations through migration", ctx do
    seed(ctx.db, %{a: "one", b: "two"})
    Manifest.write(ctx.db, %{}, ctx.path)
    {:ok, data} = Manifest.load(ctx.path)

    entries =
      Enum.map(data.memo_entries, fn entry ->
        case elem(entry, 7) do
          {:packed, logical, _, _, _} = handle ->
            {:ok, bytes} = Value.load_bytes(ctx.store, handle)
            {:ok, ^logical} = Blob.put_encoded_term(ctx.store, logical, bytes)
            put_elem(entry, 7, {:blob, logical})

          _ ->
            entry
        end
      end)

    payload = :erlang.term_to_binary(%{data | memo_entries: entries})

    for format <- [5, 6] do
      File.write!(ctx.path, ["ROUXMNFT", <<format::32, :erlang.crc32(payload)::32>>, payload])
      old = handles(ctx.path)
      db = restore(ctx.store, ctx.path)
      assert "one" == PersistQueries.p_blob(db, :a)
      Manifest.write(db, %{}, ctx.path)
      assert handles(ctx.path) == old
      assert {:ok, %{vsn: 7}} = Manifest.load(ctx.path)
    end
  end

  defp database(store) do
    db = Database.new(blob: store)
    Roux.Lang.register_module(db, PersistQueries)

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    db
  end

  defp restore(store, path) do
    db = database(store)
    {:ok, data} = Manifest.load(path)
    :ok = Manifest.restore(db, data)
    db
  end

  defp seed(db, values) do
    for {key, value} <- values do
      Input.set(db, :psrc, key, value)
      assert PersistQueries.p_blob(db, key) == value
    end
  end

  defp handles(path) do
    {:ok, data} = Manifest.load(path)

    for {{:p_blob, key}, _, _, _, _, _, _, handle, _, _} <- data.memo_entries,
        into: %{},
        do: {key, handle}
  end

  defp roots(handles), do: handles |> Map.values() |> Enum.flat_map(&Value.roots/1) |> Enum.uniq()

  defp age_all(store) do
    old = System.os_time(:second) - 3 * 24 * 60 * 60

    for path <-
          Path.wildcard(Path.join([store.root, "cas", "*", "*"])) ++
            Path.wildcard(Path.join([store.root, "roots", "*"])),
        do: File.touch!(path, old)
  end
end
