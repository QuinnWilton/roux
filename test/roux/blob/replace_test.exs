defmodule Roux.Blob.ReplaceTest do
  @moduledoc """
  The empty entry — every empty relation of every solve links it — put
  and adopted over and over by two OS processes while a third links and
  reads it. On APFS a rename that replaces a name leaves it missing for
  a moment, and a link or open then fails although the entry is there:
  a store that installed or adopted by rename failed thousands of these
  links a second. An entry is never replaced now, and every link and
  read succeeds.
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

  test "links and reads of the empty entry never fail while it is put and adopted",
       %{tmp_dir: tmp} do
    store = Blob.open!(Path.join(tmp, "store"))
    {:ok, _} = Blob.put(store, "")
    [adopter, putter, linker] = for _ <- 1..3, do: peer!()

    runs =
      for {peer, fun} <-
            [adopt_loop: adopter, put_loop: putter, link_loop: linker]
            |> Enum.map(fn {f, p} -> {p, f} end) do
        Task.async(fn -> :peer.call(peer, BlobStress, fun, [store, @ms], 60_000) end)
      end

    [adopted, put, linked] = Task.await_many(runs, 60_000)

    assert adopted > 0 and put > 0
    assert linked.links > 0
    assert linked.failed_links == []
    assert linked.misses == 0
  end
end
