defmodule Roux.Concurrency.TracePackGcTest do
  @moduledoc "A packed trace used during collection keeps its referenced blobs."

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO
  alias Roux.Blob.Trace
  alias Roux.Blob.Trace.Pack
  alias Roux.Test.{BlobFixture, ModelFS}

  def concuerror_options do
    [treat_as_normal: [:shutdown], depth_bound: 10_000, dpor: :source, scheduling_bound: 2]
  end

  def test do
    {fs, store} = BlobFixture.store()
    store = %{store | refresh: 0}
    {:ok, digest} = Blob.put(store, "referenced")
    Pack.with_group(store, :group, fn -> Pack.put(store, :value, [], digest) end)

    for kind <- ["traces", "cas"],
        dir <- RawIO.ls(Path.join(store.root, kind)),
        file <- RawIO.ls(Path.join([store.root, kind, dir])) do
      RawIO.utime(Path.join([store.root, kind, dir, file]), 0)
    end

    parent = self()

    spawn(fn ->
      ModelFS.enter(fs, "2")
      Blob.gc(store, grace: 0, keep: 0)
      send(parent, :collected)
    end)

    spawn(fn ->
      ModelFS.enter(fs, "3")

      result =
        Pack.with_group(
          store,
          :group,
          fn ->
            # Populate the snapshot before racing a later lookup against GC.
            Pack.fetch(store, :absent)

            case Trace.find(Pack.fetch(store, :value), :value, fn _ -> nil end) do
              {:ok, ^digest} ->
                {:ok, "referenced"} = Blob.get(store, digest)
                :hit

              :miss ->
                :miss
            end
          end,
          lookup: :snapshot
        )

      send(parent, {:read, result})
    end)

    receive do: (:collected -> :ok)
    receive do: ({:read, _result} -> :ok)
  end
end
