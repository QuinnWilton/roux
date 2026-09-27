# Concuerror scenarios for the blob store (`Roux.Blob`), over a model file
# system (`Roux.Test.ModelFS`) whose every step is a scheduling point and
# whose replacing rename leaves the name absent for a moment, as APFS's
# does for a concurrent link(2) or open.
#
# Run with:
#   MIX_ENV=test mix concuerror -m Roux.Concurrency.BlobPutLinkTest
#   MIX_ENV=test mix concuerror --all

defmodule Roux.Concurrency.BlobPutLinkTest do
  @moduledoc """
  Two processes of one VM put the same bytes (the empty entry every
  empty relation links) while neither finds it there; a third links the
  entry into its scratch directory once the first put returned. The link
  must succeed: the entry is there, and nothing may take its name away,
  even for a moment.
  """

  alias Roux.Blob
  alias Roux.Test.{BlobFixture, ModelFS}

  def concuerror_options, do: [treat_as_normal: [:shutdown], depth_bound: 5_000]

  def test do
    {fs, store} = BlobFixture.store()
    digest = BlobFixture.empty()
    dest = Path.join(BlobFixture.scratch_dir("1-9"), "in.facts")
    parent = self()

    linker =
      spawn(fn ->
        ModelFS.enter(fs, "1")

        receive do
          :installed -> send(parent, {:linked, Blob.link(store, digest, dest)})
        end
      end)

    spawn(fn ->
      ModelFS.enter(fs, "1")
      {:ok, ^digest} = Blob.put(store, "")
      send(linker, :installed)
    end)

    spawn(fn ->
      ModelFS.enter(fs, "1")
      {:ok, ^digest} = Blob.put(store, "")
      send(parent, :second_put)
    end)

    receive(do: (:second_put -> :ok))
    :ok = receive(do: ({:linked, result} -> result))
    {:ok, ""} = Blob.get(store, digest)
    :ok
  end
end

defmodule Roux.Concurrency.BlobAdoptLinkTest do
  @moduledoc """
  A solve adopts an output that is empty — bytes the store already
  holds — while another process links the empty entry into its scratch
  directory. The link must succeed, and the adopted output must be in
  the store afterwards, its scratch name gone.
  """

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO
  alias Roux.Test.{BlobFixture, ModelFS}

  def concuerror_options, do: [treat_as_normal: [:shutdown], depth_bound: 5_000]

  def test do
    {fs, store} = BlobFixture.store()
    digest = BlobFixture.empty()
    {:ok, ^digest} = Blob.put(store, "")
    output = Path.join(BlobFixture.scratch_dir("1-1"), "out.csv")
    :ok = RawIO.write(output, "")
    dest = Path.join(BlobFixture.scratch_dir("1-2"), "in.facts")
    parent = self()

    spawn(fn ->
      ModelFS.enter(fs, "1")
      send(parent, {:adopted, Blob.adopt(store, output)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "1")
      send(parent, {:linked, Blob.link(store, digest, dest)})
    end)

    {:ok, ^digest} = receive(do: ({:adopted, result} -> result))
    :ok = receive(do: ({:linked, result} -> result))
    {:error, :enoent} = RawIO.stat(output)
    {:ok, ""} = Blob.get(store, digest)
    :ok
  end
end
