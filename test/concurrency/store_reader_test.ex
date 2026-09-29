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
