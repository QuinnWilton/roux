defmodule Roux.Blob.Trace do
  @moduledoc """
  Verifying traces: a value kept with what computing it observed, reused
  only while every observation still holds.

      deps = [{{:file, path}, stamp(path)}, {{:env, "LANG"}, System.get_env("LANG")}]
      :ok = Roux.Blob.Trace.put(store, {:parse, path}, deps, parsed)

      Roux.Blob.Trace.find(store, {:parse, path}, fn
        {:file, path} -> stamp(path)
        {:env, name} -> System.get_env(name)
      end)

  A name keeps several traces, one per distinct set of observations: a
  value computed before an edit is found again once the edit is undone.
  `find/4` tries the most recently used first, observing each dependency
  at most once, and refreshes the trace it returns (`Roux.Blob`'s "Raw
  I/O, and touches that refresh": within the store's refresh interval,
  it is left alone), so "recently used" means used, not only written —
  and a collection (`Roux.Blob.gc/2`) keeps traces in use, and the
  entries their values name. Recency is known to within that interval.

  ## Bounded history

  Every set of observations a name ever met would otherwise stay until
  a collection, and a lookup reads and decodes them all. So history is
  bounded at both ends:

    * `put/5` keeps a name's `keep:` most recently used traces (8 by
      default) and removes the rest, each renamed aside and then
      unlinked, so a reader finds a trace whole or not at all: what a
      lookup costs never grows with how long a name has been in use.
    * `fetch/3` and `find/4` take `limit:`: they stat a name's traces
      and read and decode only the `limit` most recently used.

  Several OS processes may put and look up one name at once: a trace
  removed as a lookup reaches it is passed over, so a lookup is a hit or
  a miss, never an error.
  """

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO

  @typedoc "What computing a value observed: `{what was looked at, what it was}`."
  @type dep :: {term(), term()}

  @typedoc """
  A trace: its name, its observations, the value they gave, where it is
  kept, when it was last used (its modification time, POSIX seconds), and
  the refresh interval of the store it came from.
  """
  @type t :: %{
          name: term(),
          deps: [dep()],
          value: term(),
          path: Path.t(),
          mtime: integer(),
          refresh: non_neg_integer()
        }

  @default_keep 8

  @doc """
  Keeps `value` under `name`, with the observations `deps` it was
  computed from. Replaces a trace of the same name and observations,
  and removes all but the `keep:` most recently used traces of the name
  (this one among them).

  ## Options

    * `:keep` — how many traces the name keeps: a positive integer (default
      #{@default_keep}), or `:infinity`.
  """
  @spec put(Blob.t(), term(), [dep()], term(), keyword()) :: :ok | {:error, File.posix()}
  def put(%Blob{root: root} = store, name, deps, value, opts \\ []) when is_list(deps) do
    keep = opts |> Keyword.validate!(keep: @default_keep) |> Keyword.fetch!(:keep)

    unless keep == :infinity or (is_integer(keep) and keep > 0) do
      raise ArgumentError, ":keep must be a positive integer or :infinity, got: #{inspect(keep)}"
    end

    dir = dir(root, name)
    path = Path.join(dir, Blob.term_digest(deps))
    data = :erlang.term_to_binary({name, deps, value}, [:deterministic, {:compressed, 1}])
    staging = Path.join([root, "tmp", "#{:os.getpid()}-#{System.unique_integer([:positive])}"])

    with :ok <- RawIO.mkdir_p(dir),
         :ok <- RawIO.mkdir_p(Path.dirname(staging)),
         :ok <- RawIO.write(staging, data) do
      case RawIO.rename(staging, path) do
        :ok ->
          prune(store, dir, path, keep)

        {:error, _} = error ->
          RawIO.delete(staging)
          error
      end
    end
  end

  # All but the `keep` most recently used traces of a directory go; the
  # one just written always stays.
  defp prune(_store, _dir, _written, :infinity), do: :ok

  defp prune(store, dir, written, keep) do
    dir
    |> by_recency()
    |> Enum.map(&elem(&1, 1))
    |> Enum.reject(&(&1 == written))
    |> Enum.drop(keep - 1)
    |> Enum.each(&Blob.discard(store, &1))
  end

  @doc """
  The traces kept under `name`, the most recently used first.

  ## Options

    * `:limit` — read and decode only the `limit` most recently used
      (default: all of them). The others are looked at with one `stat`
      each.
  """
  @spec fetch(Blob.t(), term(), keyword()) :: [t()]
  def fetch(%Blob{root: root} = store, name, opts \\ []) do
    limit = opts |> Keyword.validate!(limit: :all) |> Keyword.fetch!(:limit)

    unless limit == :all or (is_integer(limit) and limit >= 0) do
      raise ArgumentError, ":limit must be a non-negative integer or :all, got: #{inspect(limit)}"
    end

    stamped = by_recency(dir(root, name))
    stamped = if limit == :all, do: stamped, else: Enum.take(stamped, limit)
    refresh = Blob.refresh_interval(store)

    # A trace removed since the listing (by a prune, a collection) is not
    # there to read, and is passed over.
    for {mtime, path} <- stamped,
        {:ok, data} <- [RawIO.read(path)],
        {:ok, {^name, deps, value}} <- [Blob.decode(data)] do
      %{name: name, deps: deps, value: value, path: path, mtime: mtime, refresh: refresh}
    end
  end

  # A directory's trace files as `{mtime, path}`, the most recently used
  # (modified) first: a file gone between the listing and its stat is
  # left out.
  defp by_recency(dir) do
    for file <- RawIO.ls(dir),
        path = Path.join(dir, file),
        {:ok, %File.Stat{mtime: mtime}} <- [RawIO.stat(path)] do
      {mtime, path}
    end
    |> Enum.sort(:desc)
  end

  @doc """
  The value of a trace under `name` whose observations all still hold —
  `observe.(what)` equal (`===`) to what was observed — or `:miss`.
  `source` is a store, or traces already fetched from one (`fetch/3`).
  The trace found is touched: it is now the name's most recently used.

  ## Options

    * `:limit` — with a store, look among only the `limit` most recently
      used traces of `name` (`fetch/3`).
  """
  @spec find(Blob.t() | [t()], term(), (term() -> term()), keyword()) :: {:ok, term()} | :miss
  def find(source, name, observe, opts \\ [])

  def find(%Blob{} = store, name, observe, opts),
    do: find(fetch(store, name, opts), name, observe, [])

  def find(traces, name, observe, _opts) when is_list(traces) and is_function(observe, 1) do
    traces
    |> Enum.filter(&(&1.name === name))
    |> Enum.reduce_while(%{}, fn trace, seen ->
      case holds(trace.deps, observe, seen) do
        {:ok, _seen} ->
          touch(trace)
          {:halt, {:found, trace.value}}

        {:changed, seen} ->
          {:cont, seen}
      end
    end)
    |> case do
      {:found, value} -> {:ok, value}
      _seen -> :miss
    end
  end

  defp holds([], _observe, seen), do: {:ok, seen}

  defp holds([{what, observed} | rest], observe, seen) do
    {now, seen} =
      case seen do
        %{^what => now} ->
          {now, seen}

        %{} ->
          now = observe.(what)
          {now, Map.put(seen, what, now)}
      end

    if now === observed, do: holds(rest, observe, seen), else: {:changed, seen}
  end

  # Marks a trace used, unless it was within its store's refresh interval.
  # A trace removed since it was read cannot be touched, and need not be.
  defp touch(%{path: path, mtime: mtime, refresh: refresh}) do
    if System.os_time(:second) - mtime >= refresh, do: _ = Blob.touch(path)
    :ok
  end

  defp dir(root, name), do: Path.join([root, "traces", Blob.term_digest(name)])
end
