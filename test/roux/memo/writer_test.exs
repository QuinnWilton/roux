defmodule Roux.Memo.WriterTest do
  use ExUnit.Case, async: true

  alias Roux.Blob
  alias Roux.Memo.{Value, Writer}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir}, do: %{store: Blob.open!(Path.join(dir, "store"))}

  test "pack byte and record bounds preserve each independently encoded value", %{store: store} do
    values = Enum.map(1..7, fn _ -> :crypto.strong_rand_bytes(340_000) end)
    entries = write(store, values)
    assert length(roots(entries)) == 3
    assert Enum.all?(roots(entries), &(File.stat!(Blob.path(store, &1)).size <= 1024 * 1024))
    assert values == read(store, entries)

    small = Enum.to_list(1..1100)
    entries = write(store, small)
    assert length(roots(entries)) == 2
    assert small == read(store, entries)
    groups = Enum.frequencies_by(entries, &(elem(&1, 7) |> Value.roots()))
    assert Enum.sort(Map.values(groups)) == [76, 1024]
  end

  test "failed publications fall back to the exact encoded records", %{tmp_dir: dir} do
    missing = %Blob{root: Path.join(dir, "no-store")}
    values = [%{one: 1}, %{two: 2}]
    entries = write(missing, values)
    assert Enum.all?(entries, &is_binary(elem(&1, 7)))
    assert read(nil, entries) == values
  end

  test "sparse maintenance moves at most four packs per checkpoint", %{store: store} do
    survivors =
      for n <- 1..5 do
        [_large, small] = write(store, [:crypto.strong_rand_bytes(600_000), {:small, n}])
        small
      end

    old = roots(survivors)
    assert length(old) == 5
    compacted = reuse(store, survivors)
    assert length(old -- roots(compacted)) == 4
    again = reuse(store, compacted)
    assert old -- roots(again) == old
    assert read(store, again) == Enum.map(1..5, &{:small, &1})
  end

  test "writer cleanup is scoped even when the memo fold raises", %{store: store} do
    keys = Process.get_keys()

    assert_raise RuntimeError, "interrupted", fn ->
      Writer.run(store, store, fn publisher ->
        {digest, bytes} = Blob.encode_term(:value)
        publisher.({:term, digest, bytes}, nil)
        raise "interrupted"
      end)
    end

    assert MapSet.new(Process.get_keys()) == MapSet.new(keys)
    assert read(store, write(store, [:after])) == [:after]
  end

  defp write(store, values) do
    Writer.run(store, store, fn publisher ->
      for {value, i} <- Enum.with_index(values) do
        {digest, bytes} = Blob.encode_term(value)
        entry(i, publisher.({:term, digest, bytes}, nil))
      end
    end)
  end

  defp reuse(store, entries) do
    Writer.run(store, store, fn publisher ->
      Enum.map(entries, &put_elem(&1, 7, publisher.(nil, elem(&1, 7))))
    end)
  end

  defp read(store, entries) do
    Enum.map(entries, fn entry ->
      {:ok, bytes} = Value.load_bytes(store, elem(entry, 7))
      {:ok, value} = Blob.decode(bytes)
      value
    end)
  end

  defp roots(entries), do: entries |> Enum.flat_map(&Value.roots(elem(&1, 7))) |> Enum.uniq()
  defp entry(key, handle), do: {key, 0, 1, 1, [], :medium, [], handle, nil, []}
end
