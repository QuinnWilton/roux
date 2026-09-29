# Concuerror scenarios for what a fresh reader of the blob store finds:
# an entry written, then read back within the refresh interval, with
# nothing it depends on changed, is found. Over the model file system
# (`Roux.Test.ModelFS`), as the other blob scenarios are.
#
# Run with:
#   MIX_ENV=test mix concuerror -m Roux.Concurrency.TraceCountPruneTest
#   MIX_ENV=test mix concuerror --all

defmodule Roux.Concurrency.TraceRewriteTest do
  @moduledoc """
  A name's one trace (no observations: a value replaced whole, as a
  cell) is put again with a new value while a reader looks it up. The
  old value is one a store of roux 0.2.1 kept, which the put removes at
  once (a version written this second would stay for a second). The
  reader finds the old value or the new one — the trace is there all
  along — and a reader after the put finds the new one.
  """

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO
  alias Roux.Blob.Trace
  alias Roux.Test.{BlobFixture, ModelFS}

  def concuerror_options, do: [treat_as_normal: [:shutdown], depth_bound: 5_000]

  def test do
    {fs, store} = BlobFixture.store()
    dir = Path.join([store.root, "traces", Blob.term_digest(:t)])
    :ok = RawIO.mkdir_p(dir)

    :ok =
      RawIO.write(Path.join(dir, Blob.term_digest([])), :erlang.term_to_binary({:t, [], :old}))

    {:ok, :old} = Trace.find(store, :t, fn _ -> :never end)
    parent = self()

    spawn(fn ->
      ModelFS.enter(fs, "2")
      send(parent, {:put, Trace.put(store, :t, [], :new, keep: 1)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "3")
      send(parent, {:found, Trace.find(store, :t, fn _ -> :never end)})
    end)

    :ok = receive(do: ({:put, result} -> result))
    found = receive(do: ({:found, result} -> result))
    true = found in [{:ok, :old}, {:ok, :new}]
    {:ok, :new} = Trace.find(store, :t, fn _ -> :never end)
    :ok
  end
end

defmodule Roux.Concurrency.RecallRememberTest do
  @moduledoc """
  An action-cache key is remembered again with another value while a
  reader recalls it. The reader recalls the old value or the new one,
  and a recall after the write recalls the new one.
  """

  alias Roux.Blob
  alias Roux.Test.{BlobFixture, ModelFS}

  def concuerror_options, do: [treat_as_normal: [:shutdown], depth_bound: 5_000]

  def test do
    {fs, store} = BlobFixture.store()
    :ok = Blob.remember(store, :k, :old)
    parent = self()

    spawn(fn ->
      ModelFS.enter(fs, "2")
      send(parent, {:remembered, Blob.remember(store, :k, :new)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "3")
      send(parent, {:recalled, Blob.recall(store, :k)})
    end)

    :ok = receive(do: ({:remembered, result} -> result))
    recalled = receive(do: ({:recalled, result} -> result))
    true = recalled in [{:ok, :old}, {:ok, :new}]
    {:ok, :new} = Blob.recall(store, :k)
    :ok
  end
end

defmodule Roux.Concurrency.TraceSegmentGcTest do
  @moduledoc """
  A trace names a segment in the CAS, both just written. A collection
  runs (its grace clamped to the refresh interval), a second writer puts
  the segment's bytes again and a third adopts a file of them, while a
  reader finds the trace and reads the segment it names: it must read
  it, and the segment must be there afterwards.
  """

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO
  alias Roux.Blob.Trace
  alias Roux.Test.{BlobFixture, ModelFS}

  def concuerror_options do
    [treat_as_normal: [:shutdown], depth_bound: 8_000, dpor: :source, scheduling_bound: 4]
  end

  def test do
    {fs, store} = BlobFixture.store()
    {digest, encoded} = Blob.encode_term(:rows)
    {:ok, ^digest} = Blob.put_encoded_term(store, digest, encoded)
    :ok = Trace.put(store, :t, [], %{segment: digest}, keep: 1)
    output = Path.join(BlobFixture.scratch_dir("1-1"), "out")
    :ok = RawIO.write(output, encoded)
    parent = self()

    spawn(fn ->
      ModelFS.enter(fs, "2")
      send(parent, {:gc, Blob.gc(store, grace: 0, keep: 0)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "3")
      send(parent, {:put, Blob.put_encoded_term(store, digest, encoded)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "1")
      send(parent, {:adopted, Blob.adopt(store, output)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "4")

      read =
        with {:ok, %{segment: segment}} <- Trace.find(store, :t, fn _ -> :never end),
             do: Blob.get_term(store, segment)

      send(parent, {:read, read})
    end)

    %{} = receive(do: ({:gc, stats} -> stats))
    {:ok, ^digest} = receive(do: ({:put, result} -> result))
    {:ok, ^digest} = receive(do: ({:adopted, result} -> result))
    {:ok, :rows} = receive(do: ({:read, result} -> result))
    {:ok, :rows} = Blob.get_term(store, digest)
    :ok
  end
end

defmodule Roux.Concurrency.TraceStaleSegmentGcTest do
  @moduledoc """
  A trace unused for longer than a collection's keep period names a
  segment as old. A reader finds the trace — a hit, which marks it used —
  and reads the segment, while a collection runs. Whatever a reader
  finds, it can read: a hit reads the segment, then and afterwards; a
  collection that takes the trace leaves the reader a miss.
  """

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO
  alias Roux.Blob.Trace
  alias Roux.Test.{BlobFixture, ModelFS}

  def concuerror_options do
    [treat_as_normal: [:shutdown], depth_bound: 8_000, dpor: :source, scheduling_bound: 4]
  end

  def test do
    {fs, store} = BlobFixture.store()
    {digest, encoded} = Blob.encode_term(:rows)
    {:ok, ^digest} = Blob.put_encoded_term(store, digest, encoded)
    :ok = Trace.put(store, :t, [], %{segment: digest}, keep: 1)
    [%{path: trace}] = Trace.fetch(store, :t)
    old = System.os_time(:second) - 8 * 24 * 60 * 60
    :ok = RawIO.utime(trace, old)
    :ok = RawIO.utime(Blob.path(store, digest), old)
    parent = self()

    spawn(fn ->
      ModelFS.enter(fs, "2")
      send(parent, {:gc, Blob.gc(store)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "3")
      send(parent, {:read, read(store)})
    end)

    %{} = receive(do: ({:gc, stats} -> stats))
    true = receive(do: ({:read, read} -> read in [:miss, {:hit, {:ok, :rows}}]))
    true = read(store) in [:miss, {:hit, {:ok, :rows}}]
    :ok
  end

  defp read(store) do
    case Trace.find(store, :t, fn _ -> :never end) do
      {:ok, %{segment: segment}} -> {:hit, Blob.get_term(store, segment)}
      :miss -> :miss
    end
  end
end
