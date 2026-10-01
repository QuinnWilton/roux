defmodule Roux.Concurrency.BlobKeepGcTest do
  @moduledoc """
  A memo checkpoint refreshes an old physical pack while collection sweeps it.
  A successful refresh must keep the complete file; a miss lets the writer
  republish its cached bytes or drop the missing restored value.
  """

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO
  alias Roux.Test.{BlobFixture, ModelFS}

  def concuerror_options do
    [treat_as_normal: [:shutdown], depth_bound: 5_000, dpor: :source, scheduling_bound: 4]
  end

  def test do
    {fs, store} = BlobFixture.store()
    digest = BlobFixture.empty()
    {:ok, ^digest} = Blob.put(store, "")
    :ok = RawIO.utime(Blob.path(store, digest), 0)
    parent = self()

    spawn(fn ->
      ModelFS.enter(fs, "2")
      send(parent, {:gc, Blob.gc(store)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "1")
      send(parent, {:kept, Blob.keep(store, digest)})
    end)

    %{} = receive(do: ({:gc, stats} -> stats))

    case receive(do: ({:kept, result} -> result)) do
      {:ok, 0} -> {:ok, ""} = Blob.get(store, digest)
      :miss -> :ok
    end

    :ok
  end
end
