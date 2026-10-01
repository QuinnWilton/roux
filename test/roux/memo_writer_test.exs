defmodule Roux.MemoWriterTest do
  # Blob.IO's instrumentation hook is VM-wide.
  use ExUnit.Case, async: false

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO
  alias Roux.Memo.{Value, Writer}

  @moduletag :tmp_dir

  test "a newly flushed pack is not compacted while references are still pending", %{tmp_dir: dir} do
    store = Blob.open!(Path.join(dir, "store"))

    encoded =
      for n <- 1..1030 do
        {digest, bytes} = Blob.encode_term({:value, n})
        {:term, digest, bytes}
      end

    parent = self()
    RawIO.install_hook(fn op, _path -> if op == :read_slice, do: send(parent, :read_back) end)

    entries =
      try do
        Writer.run(store, store, fn publish ->
          for {value, n} <- Enum.with_index(encoded ++ [hd(encoded)]) do
            {n, 0, 0, 0, [], :medium, [], publish.(value, nil), nil, []}
          end
        end)
      after
        RawIO.remove_hook()
      end

    refute_received :read_back
    assert elem(hd(entries), 7) == elem(List.last(entries), 7)

    for entry <- entries do
      assert {:ok, bytes} = Value.load_bytes(store, elem(entry, 7))
      assert {:ok, {:value, _}} = Blob.decode(bytes)
    end
  end
end
