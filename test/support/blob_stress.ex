defmodule Roux.Test.BlobStress do
  @moduledoc """
  Loops run in peer VMs (separate OS processes) against one store, for
  `Roux.Blob.ReplaceTest`: each runs for `ms` milliseconds and reports
  what it saw.
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
