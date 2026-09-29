defmodule Roux.Blob.VersionsTest do
  @moduledoc """
  A trace and an action-cache entry given a new value over and over by
  two OS processes while a third looks them up. Replaced by a rename,
  the name was missing for a moment on APFS, and a lookup then missed
  although a value was there all along. Each value is a version of its
  own now, the new one linked before the old one goes, and every lookup
  finds one.
  """

  use ExUnit.Case, async: true

  alias Roux.Blob
  alias Roux.Test.BlobStress

  @moduletag :tmp_dir

  @ms 1_500

  defp peer! do
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})
    :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    peer
  end

  test "lookups of a trace and an entry rewritten by two processes never miss", %{tmp_dir: tmp} do
    store = Blob.open!(Path.join(tmp, "store"))
    :ok = Blob.Trace.put(store, :cell, [], :seed, keep: 1)
    :ok = Blob.remember(store, :key, :seed)
    [first, second, reader] = for _ <- 1..3, do: peer!()

    runs = [
      Task.async(fn ->
        :peer.call(first, BlobStress, :rewrite_loop, [store, :a, @ms], 60_000)
      end),
      Task.async(fn ->
        :peer.call(second, BlobStress, :rewrite_loop, [store, :b, @ms], 60_000)
      end),
      Task.async(fn -> :peer.call(reader, BlobStress, :lookup_loop, [store, @ms], 60_000) end)
    ]

    [a, b, looked] = Task.await_many(runs, 60_000)

    assert a > 0 and b > 0
    assert looked.lookups > 0
    assert looked.misses == 0
  end
end
