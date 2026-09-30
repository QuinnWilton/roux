defmodule Roux.CodeConcurrencyTest do
  use ExUnit.Case, async: true

  alias Roux.Test.CodeCacheProbe

  setup do
    # Code memoization and call counters are VM-wide.
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2"]})
    :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    %{peer: peer}
  end

  test "concurrent callers share one cold closure computation", %{peer: peer} do
    assert {1, true, false} = :peer.call(peer, CodeCacheProbe, :concurrent, [], 20_000)
  end

  test "a waiter retries after the computing process exits", %{peer: peer} do
    assert {{:ok, [{Roux.Test.VersionedHelper, path}]}, 2} =
             :peer.call(peer, CodeCacheProbe, :owner_exit, [], 20_000)

    assert is_binary(path)
  end

  test "a digest may demand another closure while holding its own lock", %{peer: peer} do
    assert {:ok, digest} = :peer.call(peer, CodeCacheProbe, :nested, [], 20_000)
    assert byte_size(digest) == 64
  end

  test "nested closures cannot deadlock owners of different cold keys", %{peer: peer} do
    assert [{:ok, first}, {:ok, second}] =
             :peer.call(peer, CodeCacheProbe, :cross_calls, [], 20_000)

    assert [{Roux.Test.VersionedHelper, _}] = first
    assert [{CodeCacheProbe.Other, _}] = second
  end

  test "separate cold walks read the invariant OTP root only once", %{peer: peer} do
    assert 1 == :peer.call(peer, CodeCacheProbe, :root_reads, [], 20_000)
  end
end
