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

defmodule Roux.Concurrency.BlobGcLinkTest do
  @moduledoc """
  A collection sweeps an old entry nothing retains while a process puts
  those bytes (finding them there, which marks them used) and links the
  entry into its scratch directory, and another adopts an output with
  the same bytes. The put and the link must succeed, the adopted output
  must not be lost, and the entry must be there afterwards.
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
    dest = Path.join(BlobFixture.scratch_dir("1-1"), "in.facts")
    output = Path.join(BlobFixture.scratch_dir("1-2"), "out.csv")
    :ok = RawIO.write(output, "")
    parent = self()

    spawn(fn ->
      ModelFS.enter(fs, "2")
      send(parent, {:gc, Blob.gc(store)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "1")
      {:ok, ^digest} = Blob.put(store, "")
      send(parent, {:linked, Blob.link(store, digest, dest)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "1")
      send(parent, {:adopted, Blob.adopt(store, output)})
    end)

    %{} = receive(do: ({:gc, stats} -> stats))
    :ok = receive(do: ({:linked, result} -> result))
    {:ok, ^digest} = receive(do: ({:adopted, result} -> result))
    {:ok, ""} = RawIO.read(dest)
    {:ok, ""} = Blob.get(store, digest)
    :ok
  end
end

defmodule Roux.Concurrency.BlobTracePruneTest do
  @moduledoc """
  A put under a trace name, keeping one trace, prunes an old trace —
  unused for longer than the store's window — while another process
  looks the name up and finds it: the lookup is a hit on the old value
  or a miss, never a crash. The new trace is kept, and the old one
  whenever the lookup marked it used, a hit. (A miss may leave it kept
  too: the model's touch reports a name moved as it changed the inode
  as gone, where the system call would have succeeded.)
  """

  alias Roux.Blob.IO, as: RawIO
  alias Roux.Blob.Trace
  alias Roux.Test.{BlobFixture, ModelFS}

  def concuerror_options do
    [treat_as_normal: [:shutdown], depth_bound: 5_000, dpor: :source, scheduling_bound: 6]
  end

  def test do
    {fs, store} = BlobFixture.store()
    :ok = Trace.put(store, :t, [{:v, 1}], :old)
    [%{path: old}] = Trace.fetch(store, :t)
    :ok = RawIO.utime(old, System.os_time(:second) - 3 * 60 * 60)
    parent = self()

    spawn(fn ->
      ModelFS.enter(fs, "1")
      send(parent, {:put, Trace.put(store, :t, [{:v, 2}], :new, keep: 1)})
    end)

    spawn(fn ->
      ModelFS.enter(fs, "2")
      send(parent, {:found, Trace.find(store, :t, fn :v -> 1 end, limit: 8)})
    end)

    :ok = receive(do: ({:put, result} -> result))
    found = receive(do: ({:found, result} -> result))
    kept = store |> Trace.fetch(:t) |> Enum.map(& &1.value) |> Enum.sort()

    case found do
      {:ok, :old} -> [:new, :old] = kept
      :miss -> true = kept in [[:new], [:new, :old]]
    end

    :ok
  end
end

defmodule Roux.Concurrency.BlobScratchReuseTest do
  @moduledoc """
  A VM that died in a scratch directory left it behind, and a new VM is
  given the dead one's OS pid: its first scratch directory would bear
  the same name. A collection that finds the leftover a day old removes
  it, contents and all. The new owner links an input into its scratch
  directory and reads it: the read must succeed.
  """

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO
  alias Roux.Test.{BlobFixture, ModelFS}

  def concuerror_options do
    [treat_as_normal: [:shutdown], depth_bound: 5_000, dpor: :source, scheduling_bound: 6]
  end

  def test do
    {fs, store} = BlobFixture.store()
    digest = BlobFixture.empty()
    {:ok, ^digest} = Blob.put(store, "")
    # Model OS process "7" once made scratch "7-1", and died in it.
    leftover = BlobFixture.scratch_dir("7-1")
    :ok = RawIO.utime(leftover, 0)
    parent = self()

    spawn(fn ->
      ModelFS.enter(fs, "2")
      send(parent, {:gc, Blob.gc(store)})
    end)

    spawn(fn ->
      # The new VM with the reused pid: its unique integers start at 1.
      ModelFS.enter(fs, "7")

      result =
        Blob.scratch(store, fn dir ->
          input = Path.join(dir, "in.facts")
          :ok = Blob.link(store, digest, input)
          RawIO.read(input)
        end)

      send(parent, {:read, result})
    end)

    %{} = receive(do: ({:gc, stats} -> stats))
    {:ok, ""} = receive(do: ({:read, result} -> result))
    :ok
  end
end
