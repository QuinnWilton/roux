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
  at most once, and marks the trace it returns used (`mark_used/1`:
  within the store's refresh interval, it is left alone — `Roux.Blob`'s
  "Raw I/O, and touches that refresh"), so "recently used" means used,
  not only written — and a collection (`Roux.Blob.gc/2`) keeps traces in
  use, and the entries their values name.

  ## Versions

  A trace is never replaced in place: a rename onto a name is not atomic
  everywhere, and a reader that meets its moment finds no trace at all.
  Each value a trace holds is a version, a file of its own named by the
  digest of its observations, the time it was written and the digest of
  its bytes, linked into place and never changed — the store's CAS
  entries' rule (`Roux.Blob`'s "Entries"). A put of another value under
  the same observations adds a version, then removes the versions it
  found there that were written more than a second before it: a reader
  that listed one a moment ago can still read it. A lookup reads each
  set of observations' newest version, by the time in its name (a
  modification time, in whole seconds, cannot order two versions of one
  second); one removed between its listing and its read is looked for
  again. So a reader always finds a complete version, and after a put,
  the one it wrote. Putting the bytes of the newest version again writes
  nothing, and marks it used.

  ## Bounded history

  Every set of observations a name ever met would otherwise stay until
  a collection, and a lookup reads and decodes them all. So history is
  bounded at both ends:

    * `put/5` keeps a name's `keep:` most recently used traces (8 by
      default), and every trace written or used within the store's
      window (`Roux.Blob.window/1`, twice its refresh interval: a trace
      used within the interval was marked within the window), however
      many: an older one goes, renamed aside and then removed (or put
      back, if a lookup marked it used meanwhile), so a reader finds a
      trace whole or not at all.
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

  # How many times a lookup looks again for a trace removed as it read
  # it: each is another process's put, prune or collection meanwhile.
  @attempts 3

  # How long a superseded version stays, in microseconds: a reader that
  # listed it before the put that superseded it can still read it.
  @superseded_grace 1_000_000

  @doc """
  Keeps `value` under `name`, with the observations `deps` it was
  computed from: a new version of the trace of those observations (see
  "Versions"), and the only one once this returns, unless another
  process put one meanwhile. Keeps the `keep:` most recently used traces
  of the name, and every one used within the window (see "Bounded
  history").

  ## Options

    * `:keep` — how many traces the name keeps beyond the window: a
      positive integer (default #{@default_keep}), or `:infinity`.
  """
  @spec put(Blob.t(), term(), [dep()], term(), keyword()) :: :ok | {:error, File.posix()}
  def put(%Blob{root: root} = store, name, deps, value, opts \\ []) when is_list(deps) do
    keep = opts |> Keyword.validate!(keep: @default_keep) |> Keyword.fetch!(:keep)

    unless keep == :infinity or (is_integer(keep) and keep > 0) do
      raise ArgumentError, ":keep must be a positive integer or :infinity, got: #{inspect(keep)}"
    end

    dir = dir(root, name)
    group = Blob.term_digest(deps)
    data = :erlang.term_to_binary({name, deps, value}, [:deterministic, {:compressed, 1}])
    digest = Blob.digest(data)
    now = System.os_time(:microsecond)

    with :ok <- RawIO.mkdir_p(dir) do
      # The versions there before this write, oldest first: the newest
      # holding these bytes already is used, not written again.
      before = dir |> RawIO.ls() |> Enum.filter(&(group_of(&1) == group)) |> Enum.sort()

      file =
        case List.last(before) do
          nil ->
            version_name(group, now, digest)

          newest ->
            if digest_of(newest) == digest, do: newest, else: version_name(group, now, digest)
        end

      with :ok <- Blob.install(store, Path.join(dir, file), data) do
        superseded = time(now - @superseded_grace)

        for other <- before,
            other != file,
            written_at(other) < superseded,
            do: Blob.discard(store, Path.join(dir, other))

        prune(store, dir, group, keep)
      end
    end
  end

  # A version's name: its observations' digest, the time it was written
  # (microseconds, as 16 hexadecimal digits, so names sort by it), and its
  # bytes' digest. A trace roux 0.2.1 kept is named by its observations'
  # digest alone, and sorts before every version.
  defp version_name(group, microseconds, digest),
    do: Enum.join([group, time(microseconds), digest], ".")

  defp time(microseconds),
    do: microseconds |> Integer.to_string(16) |> String.pad_leading(16, "0")

  defp group_of(file), do: file |> String.split(".", parts: 2) |> hd()

  # When a version was written, as its name says — compared as written:
  # the digits are fixed in number — and "" for a trace of 0.2.1's.
  defp written_at(file) do
    case String.split(file, ".") do
      [_group, time, _digest] -> time
      _kept_by_0_2_1 -> ""
    end
  end

  defp digest_of(file) do
    case String.split(file, ".") do
      [_group, _time, digest] -> digest
      _kept_by_0_2_1 -> nil
    end
  end

  # The traces of other observations beyond `keep`, unused for longer
  # than the window, the least recently used first; the one just written
  # always stays.
  defp prune(_store, _dir, _group, :infinity), do: :ok

  defp prune(store, dir, group, keep) do
    since = System.os_time(:second) - Blob.window(store)
    others = dir |> traces() |> elem(0) |> Enum.reject(&(&1.group == group))
    {fresh, stale} = Enum.split_with(others, &(&1.mtime >= since))

    stale
    |> Enum.drop(max(keep - 1 - length(fresh), 0))
    |> Enum.each(fn trace ->
      for path <- trace.versions, do: Blob.sweep_entry(store, path, since)
    end)
  end

  @doc """
  The traces kept under `name`, the most recently used first: each set
  of observations' newest version.

  ## Options

    * `:limit` — read and decode only the `limit` most recently used
      (default: all of them). The others are looked at with one `stat`
      each.
  """
  @spec fetch(Blob.t(), term(), keyword()) :: [t()]
  def fetch(%Blob{} = store, name, opts \\ []) do
    limit = opts |> Keyword.validate!(limit: :all) |> Keyword.fetch!(:limit)

    unless limit == :all or (is_integer(limit) and limit >= 0) do
      raise ArgumentError, ":limit must be a non-negative integer or :all, got: #{inspect(limit)}"
    end

    fetch(store, name, limit, @attempts)
  end

  defp fetch(%Blob{root: root} = store, name, limit, attempts) do
    {listed, vanished?} = traces(dir(root, name))
    listed = if limit == :all, do: listed, else: Enum.take(listed, limit)
    refresh = Blob.refresh_interval(store)

    read =
      for trace <- listed do
        with {:ok, data} <- RawIO.read(trace.path),
             {:ok, {^name, deps, value}} <- Blob.decode(data) do
          %{name: name, deps: deps, value: value, path: trace.path, mtime: trace.mtime}
          |> Map.put(:refresh, refresh)
        else
          {:error, :enoent} -> :vanished
          _undecodable -> nil
        end
      end

    # A version gone between the listing and its read was superseded, or
    # taken: another look finds what took its place, if anything did.
    if (vanished? or :vanished in read) and attempts > 1 do
      fetch(store, name, limit, attempts - 1)
    else
      Enum.filter(read, &is_map/1)
    end
  end

  # A directory's traces, one per set of observations: the newest
  # version's path (by its name), the group's most recent modification
  # time, and every version's path, the most recently used first. And
  # whether a file listed was gone at its stat.
  defp traces(dir) do
    stamped =
      for file <- RawIO.ls(dir) do
        path = Path.join(dir, file)

        case RawIO.stat(path) do
          {:ok, %File.Stat{mtime: mtime}} -> {mtime, file, path}
          {:error, _} -> :vanished
        end
      end

    traces =
      stamped
      |> Enum.reject(&(&1 == :vanished))
      |> Enum.group_by(fn {_mtime, file, _path} -> group_of(file) end)
      |> Enum.map(fn {group, versions} ->
        {_mtime, file, path} = Enum.max_by(versions, &elem(&1, 1))

        %{
          group: group,
          mtime: versions |> Enum.map(&elem(&1, 0)) |> Enum.max(),
          file: file,
          path: path,
          versions: Enum.map(versions, &elem(&1, 2))
        }
      end)
      |> Enum.sort_by(&{&1.mtime, &1.file}, :desc)

    {traces, :vanished in stamped}
  end

  @doc """
  The value of a trace under `name` whose observations all still hold —
  `observe.(what)` equal (`===`) to what was observed — or `:miss`.
  `source` is a store, or traces already fetched from one (`fetch/3`).
  The trace found is marked used (`mark_used/1`): it is now the name's
  most recently used. One removed as it was found — taken by a
  collection, or superseded — is not returned: with a store, it is
  looked for again.

  ## Options

    * `:limit` — with a store, look among only the `limit` most recently
      used traces of `name` (`fetch/3`).
  """
  @spec find(Blob.t() | [t()], term(), (term() -> term()), keyword()) :: {:ok, term()} | :miss
  def find(source, name, observe, opts \\ []) do
    case find_trace(source, name, observe, opts) do
      {:ok, trace} -> {:ok, trace.value}
      :miss -> :miss
    end
  end

  @doc """
  The trace whose value `find/4` returns, observations and all: for a
  caller that keeps what a trace observed, to put it elsewhere.
  """
  @spec find_trace(Blob.t() | [t()], term(), (term() -> term()), keyword()) ::
          {:ok, t()} | :miss
  def find_trace(source, name, observe, opts \\ [])

  def find_trace(%Blob{} = store, name, observe, opts) when is_function(observe, 1),
    do: find_in(store, name, observe, opts, @attempts)

  def find_trace(traces, name, observe, _opts) when is_list(traces) and is_function(observe, 1) do
    with {:found, trace} <- holding(traces, name, observe),
         :ok <- mark_used(trace) do
      {:ok, trace}
    else
      _miss_or_gone -> :miss
    end
  end

  defp find_in(store, name, observe, opts, attempts) do
    with {:found, trace} <- holding(fetch(store, name, opts), name, observe),
         :ok <- mark_used(trace) do
      {:ok, trace}
    else
      :gone when attempts > 1 -> find_in(store, name, observe, opts, attempts - 1)
      _miss_or_gone -> :miss
    end
  end

  # The first trace whose observations all hold.
  defp holding(traces, name, observe) do
    traces
    |> Enum.filter(&(&1.name === name))
    |> Enum.reduce_while(%{}, fn trace, seen ->
      case holds(trace.deps, observe, seen) do
        {:ok, _seen} -> {:halt, {:found, trace}}
        {:changed, seen} -> {:cont, seen}
      end
    end)
    |> case do
      {:found, trace} -> {:found, trace}
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

  @doc """
  Marks a trace fetched (`fetch/3`) used, as `find/4` marks the one it
  returns: its modification time set to now, unless that is within its
  store's refresh interval. `:gone` when the trace was removed since it
  was read, which can happen only to one unused for longer than the
  interval: a collection may be taking the entries its value names, so
  that value is not to be used.
  """
  @spec mark_used(t()) :: :ok | :gone
  def mark_used(%{path: path, mtime: mtime, refresh: refresh}) do
    if System.os_time(:second) - mtime >= refresh do
      case Blob.touch(path) do
        :ok -> :ok
        {:error, _} -> :gone
      end
    else
      :ok
    end
  end

  defp dir(root, name), do: Path.join([root, "traces", Blob.term_digest(name)])
end
