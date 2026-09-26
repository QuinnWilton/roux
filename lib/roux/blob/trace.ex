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
  `find/3` tries the most recently used first, observing each dependency
  at most once, and touches the trace it returns, so a collection
  (`Roux.Blob.gc/2`) keeps traces in use — and the entries their values
  name.
  """

  alias Roux.Blob

  @typedoc "What computing a value observed: `{what was looked at, what it was}`."
  @type dep :: {term(), term()}

  @typedoc "A trace: its name, its observations, the value they gave, and where it is kept."
  @type t :: %{name: term(), deps: [dep()], value: term(), path: Path.t()}

  @doc """
  Keeps `value` under `name`, with the observations `deps` it was
  computed from. Replaces a trace of the same name and observations.
  """
  @spec put(Blob.t(), term(), [dep()], term()) :: :ok | {:error, File.posix()}
  def put(%Blob{root: root}, name, deps, value) when is_list(deps) do
    dir = dir(root, name)
    path = Path.join(dir, Blob.term_digest(deps))
    data = :erlang.term_to_binary({name, deps, value}, [:deterministic, {:compressed, 1}])
    staging = Path.join([root, "tmp", "#{:os.getpid()}-#{System.unique_integer([:positive])}"])

    with :ok <- File.mkdir_p(dir),
         :ok <- File.mkdir_p(Path.dirname(staging)),
         :ok <- File.write(staging, data) do
      case File.rename(staging, path) do
        :ok ->
          :ok

        {:error, _} = error ->
          File.rm(staging)
          error
      end
    end
  end

  @doc "Every trace kept under `name`, the most recently used first."
  @spec fetch(Blob.t(), term()) :: [t()]
  def fetch(%Blob{root: root}, name) do
    dir = dir(root, name)

    for file <- ls(dir),
        path = Path.join(dir, file),
        {:ok, %File.Stat{mtime: mtime}} <- [File.stat(path, time: :posix)],
        {:ok, data} <- [File.read(path)],
        {:ok, {^name, deps, value}} <- [Blob.decode(data)] do
      {mtime, %{name: name, deps: deps, value: value, path: path}}
    end
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  The value of a trace under `name` whose observations all still hold —
  `observe.(what)` equal (`===`) to what was observed — or `:miss`.
  `source` is a store, or traces already fetched from one (`fetch/2`).
  """
  @spec find(Blob.t() | [t()], term(), (term() -> term())) :: {:ok, term()} | :miss
  def find(%Blob{} = store, name, observe), do: find(fetch(store, name), name, observe)

  def find(traces, name, observe) when is_list(traces) and is_function(observe, 1) do
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

  defp touch(%{path: path}) do
    _ = Blob.touch(path)
    :ok
  end

  defp dir(root, name), do: Path.join([root, "traces", Blob.term_digest(name)])

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end
end
