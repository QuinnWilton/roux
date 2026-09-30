defmodule Roux.TracePackTest do
  use ExUnit.Case, async: true

  alias Roux.Blob
  alias Roux.Blob.Trace
  alias Roux.Blob.Trace.Pack

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    %{store: Blob.open!(Path.join(tmp, "store"), refresh: 0)}
  end

  defp indexes(store), do: Path.wildcard(Path.join([store.root, "traces", "pack-v1-*", "*"]))

  defp values(store, name), do: store |> Pack.fetch(name) |> Enum.map(& &1.value)

  defp age_store(store) do
    for path <- Path.wildcard(Path.join(store.root, "**/*")), File.regular?(path) do
      File.touch!(path, System.os_time(:second) - 86_400)
    end
  end

  test "bounded batches survive reopening without a manifest", %{store: store} do
    assert :result ==
             Pack.with_group(store, :module, fn ->
               for n <- 1..2050, do: Pack.put(store, {:query, n}, [{:schema, n}], {n, "result"})
               :result
             end)

    assert length(indexes(store)) == 3
    assert length(Path.wildcard(Path.join([store.root, "cas", "*", "*"]))) == 3
    reopened = Blob.open!(store.root)

    Pack.with_group(reopened, :module, fn ->
      for n <- [1, 1024, 1025, 2048, 2050] do
        assert [%{deps: [{:schema, ^n}], value: {^n, "result"}}] =
                 Pack.fetch(reopened, {:query, n})
      end
    end)
  end

  test "groups are explicit and loose traces remain readable", %{store: store} do
    :ok = Trace.put(store, :legacy, [{:version, 1}], :old)

    Pack.with_group(store, :a, fn ->
      assert values(store, :legacy) == [:old]
      :ok = Pack.put(store, :legacy, [{:version, 1}], :new)
      assert values(store, :legacy) == [:new]
      :ok = Pack.put(store, :only_a, [], :a)
    end)

    Pack.with_group(store, :b, fn ->
      assert values(store, :legacy) == [:old]
      assert values(store, :only_a) == []
    end)

    assert values(store, :legacy) == [:old]
  end

  test "isolated lookups reuse packs without creating a pack per write", %{store: store} do
    Pack.with_group(store, :module, fn -> Pack.put(store, :packed, [], :packed) end)

    Pack.with_group(
      store,
      :module,
      fn ->
        assert values(store, :packed) == [:packed]
        Pack.put(store, :loose, [], :loose)
      end,
      write: :loose
    )

    assert length(indexes(store)) == 1
    assert [%{value: :loose}] = Trace.fetch(store, :loose)

    Pack.with_group(store, :module, fn ->
      Pack.with_group(store, :module, fn -> Pack.put(store, :nested, [], :nested) end,
        write: :loose
      )
    end)

    assert length(indexes(store)) == 2
    assert Trace.fetch(store, :nested) == []
  end

  test "lookups see buffered writes and nesting restores the outer group", %{store: store} do
    Pack.with_group(store, :outer, fn ->
      Pack.put(store, :a, [], :outer)

      Pack.with_group(store, :inner, fn ->
        Pack.put(store, :a, [], :inner)
        assert values(store, :a) == [:inner]
        Pack.with_group(store, :outer, fn -> assert values(store, :a) == [:outer] end)
      end)

      Pack.with_group(store, :outer, fn ->
        assert values(store, :a) == [:outer]
        Pack.put(store, :b, [], :also_outer)
      end)
    end)

    Pack.with_group(store, :outer, fn -> assert values(store, :b) == [:also_outer] end)
    assert Pack.fetch(store, :a) == []
  end

  test "an exception drops unpublished writes and restores ordinary storage", %{store: store} do
    assert_raise RuntimeError, "failed", fn ->
      Pack.with_group(store, :failed, fn ->
        Pack.put(store, :pending, [], :pending)
        raise "failed"
      end)
    end

    assert indexes(store) == []
    Pack.put(store, :loose, [], :loose)
    assert [%{value: :loose}] = Trace.fetch(store, :loose)
  end

  test "killing a writer preserves completed packs and exposes no partial batch", %{store: store} do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Pack.with_group(
          store,
          :killed,
          fn ->
            Pack.put(store, :published, [], :published)
            Pack.put(store, :also_published, [], :also_published)
            Pack.put(store, :pending, [], :pending)
            send(parent, :buffered)

            receive do
              :finish -> :ok
            end
          end,
          max_entries: 2
        )
      end)

    assert_receive :buffered
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    Pack.with_group(store, :killed, fn ->
      assert values(store, :published) == [:published]
      assert values(store, :also_published) == [:also_published]
      assert values(store, :pending) == []
    end)
  end

  test "concurrent writers publish independent packs without overwriting each other", %{
    store: store
  } do
    for n <- 1..12 do
      Task.async(fn ->
        Pack.with_group(store, :shared, fn ->
          for j <- 1..10, do: Pack.put(store, {n, j}, [], {n, j})
        end)
      end)
    end
    |> Task.await_many()

    Pack.with_group(store, :shared, fn ->
      for n <- 1..12, j <- 1..10, do: assert(values(store, {n, j}) == [{n, j}])
    end)
  end

  test "a reader notices a new pack while its group is open", %{store: store} do
    Pack.with_group(store, :shared, fn ->
      assert Pack.fetch(store, :later) == []

      Task.async(fn ->
        Pack.with_group(store, :shared, fn -> Pack.put(store, :later, [], :new) end)
      end)
      |> Task.await()

      assert values(store, :later) == [:new]
    end)
  end

  test "observations, newest versions, lookup limits and history remain independent", %{
    store: store
  } do
    Pack.with_group(store, :versions, fn ->
      for n <- 1..5 do
        Pack.put(store, :query, [{:input, n}], n, keep: 3)
        assert values(store, :query) |> hd() == n
      end
    end)

    age_store(store)

    Pack.with_group(store, :versions, fn ->
      assert values(store, :query) == [5, 4, 3]
      assert length(Pack.fetch(store, :query, limit: 2)) == 2
      assert {:ok, 4} = Trace.find(Pack.fetch(store, :query), :query, fn :input -> 4 end)
      Pack.put(store, :query, [{:input, 5}], :replacement, keep: 3)
      assert [%{value: :replacement} | _] = Pack.fetch(store, :query)
    end)
  end

  test "GC retains payloads and indirect blobs through a live pack index", %{store: store} do
    {:ok, referenced} = Blob.put(store, "referenced by a trace")
    {:ok, unreferenced} = Blob.put(store, "unreferenced")
    Pack.with_group(store, :gc, fn -> Pack.put(store, :value, [], %{blob: referenced}) end)
    age_store(store)

    Pack.with_group(store, :gc, fn ->
      [trace] = Pack.fetch(store, :value)
      assert :ok = Trace.mark_used(trace)
      Blob.gc(store, keep: 0, grace: 0)
      assert {:ok, "referenced by a trace"} = Blob.get(store, referenced)
      assert Blob.get(store, unreferenced) == :miss
      assert values(store, :value) == [%{blob: referenced}]
    end)

    age_store(store)
    Blob.gc(store, keep: 0, grace: 0)
    assert indexes(store) == []
    assert Blob.get(store, referenced) == :miss
  end

  test "a truncated payload or corrupted index is a miss and recomputation repairs it", %{
    store: store
  } do
    Pack.with_group(store, :corrupt, fn -> Pack.put(store, :value, [], :original) end)
    [index] = indexes(store)
    {:roux_trace_pack, 1, _, blob, _, _} = index |> File.read!() |> :erlang.binary_to_term()
    path = Blob.path(store, blob)
    File.chmod!(path, 0o644)
    File.write!(path, <<>>)

    Pack.with_group(store, :corrupt, fn ->
      assert Pack.fetch(store, :value) == []
      Pack.put(store, :value, [], :original)
      assert values(store, :value) == [:original]
    end)

    for path <- indexes(store) do
      File.chmod!(path, 0o644)
      File.write!(path, "broken")
    end

    Pack.with_group(store, :corrupt, fn -> assert Pack.fetch(store, :value) == [] end)
  end

  test "size limits reject invalid values and bound a large record", %{store: store} do
    assert_raise ArgumentError, fn ->
      Pack.with_group(store, :bad, fn -> :ok end, max_bytes: 0)
    end

    Pack.with_group(
      store,
      :bytes,
      fn ->
        Pack.put(store, :large, [], :crypto.strong_rand_bytes(4096))
        assert length(indexes(store)) == 1
      end,
      max_bytes: 1024
    )
  end
end
