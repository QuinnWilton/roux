defmodule Roux.Test.BlobStress do
  @moduledoc """
  Loops run in peer VMs (separate OS processes) against one store, for
  `Roux.Blob.ReplaceTest` and `Roux.Blob.VersionsTest`: each runs for
  `ms` milliseconds and reports what it saw.
  """

  alias Roux.Blob

  @doc "Adopts a fresh empty output over and over: the bytes of the empty entry."
  def adopt_loop(store, ms) do
    Blob.scratch(store, fn dir ->
      loop(ms, 0, fn n ->
        output = Path.join(dir, "out-#{n}.csv")
        :ok = File.write(output, "")
        {:ok, _} = Blob.adopt(store, output)
      end)
    end)
  end

  @doc "Puts the empty bytes over and over."
  def put_loop(store, ms), do: loop(ms, 0, fn _n -> {:ok, _} = Blob.put(store, "") end)

  @doc """
  Links the empty entry into a scratch directory, and reads it, over and
  over: `%{links: n, failed_links: [reason], misses: n}`.
  """
  def link_loop(store, ms) do
    digest = Blob.digest("")

    Blob.scratch(store, fn dir ->
      deadline = System.monotonic_time(:millisecond) + ms

      Stream.iterate(0, &(&1 + 1))
      |> Enum.reduce_while(%{links: 0, failed_links: [], misses: 0}, fn n, acc ->
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, acc}
        else
          acc =
            case Blob.link(store, digest, Path.join(dir, "in-#{n}.facts")) do
              :ok ->
                %{acc | links: acc.links + 1}

              {:error, reason} ->
                %{acc | links: acc.links + 1, failed_links: [reason | acc.failed_links]}
            end

          acc =
            if Blob.get(store, digest) == {:ok, ""},
              do: acc,
              else: %{acc | misses: acc.misses + 1}

          {:cont, acc}
        end
      end)
    end)
  end

  @doc """
  Puts a new value in the trace `:cell` (no observations) and remembers
  one under `:key`, over and over, each value `{tag, n}`: the count.
  """
  def rewrite_loop(store, tag, ms) do
    loop(ms, 0, fn n ->
      :ok = Blob.Trace.put(store, :cell, [], {tag, n}, keep: 1)
      :ok = Blob.remember(store, :key, {tag, n})
    end)
  end

  @doc """
  Looks up the trace `:cell` and recalls `:key`, over and over:
  `%{lookups: n, misses: n}`.
  """
  def lookup_loop(store, ms) do
    deadline = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn -> :look end)
    |> Enum.reduce_while(%{lookups: 0, misses: 0}, fn :look, acc ->
      if System.monotonic_time(:millisecond) > deadline do
        {:halt, acc}
      else
        found = [Blob.Trace.find(store, :cell, fn _ -> nil end), Blob.recall(store, :key)]
        misses = Enum.count(found, &(&1 == :miss))
        {:cont, %{lookups: acc.lookups + 2, misses: acc.misses + misses}}
      end
    end)
  end

  @doc "A link of `digest` to `dest`, and a read of it: `{link result, get result}`."
  def link_and_get(store, digest, dest),
    do: {Blob.link(store, digest, dest), Blob.get(store, digest)}

  defp loop(ms, count, fun) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_loop(deadline, count, fun)
  end

  defp do_loop(deadline, count, fun) do
    if System.monotonic_time(:millisecond) > deadline do
      count
    else
      fun.(count)
      do_loop(deadline, count + 1, fun)
    end
  end
end
