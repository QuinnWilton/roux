defmodule Roux.Test.BlobFixture do
  @moduledoc """
  A blob store on a model file system (`Roux.Test.ModelFS`), for the
  Concuerror scenarios of `test/concurrency/blob_test.ex`: the store's
  directories made, the calling process entered as model OS process "1".
  """

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO
  alias Roux.Test.ModelFS

  @root "/s"

  @doc "A model file system holding an empty store, and the store."
  def store do
    fs = ModelFS.new()
    ModelFS.enter(fs, "1")

    for dir <- ~w(cas/e3 tmp trash scratch ac traces roots),
        do: :ok = RawIO.mkdir_p(Path.join(@root, dir))

    {fs, %Blob{root: @root}}
  end

  @doc "The digest of the empty bytes: the entry every empty relation links."
  def empty, do: Blob.digest("")

  @doc "A scratch directory of the calling process's own, made."
  def scratch_dir(name) do
    dir = Path.join([@root, "scratch", name])
    :ok = RawIO.mkdir_p(dir)
    dir
  end
end
