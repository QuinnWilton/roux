defmodule Roux.Blob.Trace.Pack do
  @moduledoc """
  Batches small verifying traces into immutable, indexed packs.

  `with_group/4` selects a stable storage group for `fetch/3` and `put/5`
  in the calling process. Use the same group in later sessions; other groups
  are not searched. Loose traces remain readable as a migration path. Calls
  outside a group use the ordinary `Roux.Blob.Trace` store.

  Each record is compressed and hashed separately. One CAS blob holds their
  concatenated bytes; a small index maps name hashes to offsets, versions and
  observation hashes. The index also lists referenced blobs so the existing
  collector can retain them without decoding every record.

  Writes flush at the configured size bound and before a successful return.
  Looking up a pending name flushes first, providing read-your-writes. A killed
  process loses only its unpublished batch; readers never see partial packs.
  Worker processes do not inherit a group. Nested groups restore their caller's
  group on return.

  `write: :loose` reads the group's packs but writes ordinary traces. Use it
  for isolated lookups that cannot amortize a batch. A nested call to the
  active group keeps that group's write policy and size limits.

  `lookup: :snapshot` discovers packed indexes once per group scope, refreshing
  after this process publishes a pack. Concurrent publications can be missed
  until the next scope. Use it for pure computations whose traces are still
  checked against their observations. The default `:latest` discovers packs
  on every lookup. Loose traces are always read afresh.

  Collection operates on whole packs. Using one record retains its neighbors;
  `keep:` bounds lookup history outside the refresh window, but reclaiming
  individual obsolete records requires repacking. Choose bounded groups, such
  as one source module, rather than an entire project.
  """

  alias Roux.Blob
  alias Roux.Blob.IO, as: RawIO
  alias Roux.Blob.Trace

  @context {__MODULE__, :context}
  @defaults [max_entries: 1024, max_bytes: 4 * 1024 * 1024]

  @doc "Runs `fun` with bounded packed writes in `group`, returning its result."
  @spec with_group(Blob.t(), term(), (-> result), keyword()) :: result when result: var
  def with_group(%Blob{} = store, group, fun, opts \\ []) when is_function(fun, 0) do
    opts = Keyword.validate!(opts, @defaults ++ [write: :packed, lookup: :latest])
    {write, opts} = Keyword.pop!(opts, :write)
    {lookup, limits} = Keyword.pop!(opts, :lookup)

    unless write in [:packed, :loose] do
      raise ArgumentError, "pack write policy must be :packed or :loose"
    end

    unless lookup in [:latest, :snapshot] do
      raise ArgumentError, "pack lookup policy must be :latest or :snapshot"
    end

    unless Enum.all?(limits, fn {_key, value} -> is_integer(value) and value > 0 end) do
      raise ArgumentError, "pack size limits must be positive integers"
    end

    previous = Process.get(@context)

    if match?(%{root: root, group: ^group} when root == store.root, previous) do
      fun.()
    else
      # A nested callback may re-enter this group through another group.
      # Publish its outer writes before switching, so re-entry can see them.
      if previous, do: flush!(previous.store)
      previous = Process.get(@context)

      state = %{
        store: store,
        write: write,
        lookup: lookup,
        root: store.root,
        group: group,
        dir: Path.join([store.root, "traces", "pack-v1-" <> Blob.term_digest(group)]),
        limits: limits,
        pending: %{},
        pending_names: MapSet.new(),
        bytes: 0,
        indexes: %{},
        listing: nil
      }

      Process.put(@context, state)

      try do
        result = fun.()
        flush!(store)
        result
      after
        if previous, do: Process.put(@context, previous), else: Process.delete(@context)
      end
    end
  end

  @doc "Keeps a trace in the current group, or writes a loose trace outside one."
  @spec put(Blob.t(), term(), [Trace.dep()], term(), keyword()) :: :ok | {:error, File.posix()}
  def put(%Blob{} = store, name, deps, value, opts \\ []) do
    case context(store) do
      nil ->
        Trace.put(store, name, deps, value, opts)

      %{write: :loose} ->
        Trace.put(store, name, deps, value, opts)

      state ->
        keep = opts |> Keyword.validate!(keep: 8) |> Keyword.fetch!(:keep)

        unless keep == :infinity or (is_integer(keep) and keep > 0) do
          raise ArgumentError, ":keep must be a positive integer or :infinity"
        end

        {digest, bytes} = Blob.encode_term({name, deps, value})
        key = {Blob.term_digest(name), Blob.term_digest(deps)}
        version = {System.os_time(:microsecond), digest}
        refs = Blob.referenced_digests({deps, value})
        pending = Map.put(state.pending, key, {bytes, version, refs, keep})
        # Counting replacements twice can flush early. A single oversized record
        # is published immediately rather than split across packs.
        state = %{
          state
          | pending: pending,
            bytes: state.bytes + byte_size(bytes),
            pending_names: MapSet.put(state.pending_names, elem(key, 0))
        }

        Process.put(@context, state)

        if map_size(pending) >= state.limits[:max_entries] or
             state.bytes >= state.limits[:max_bytes],
           do: flush!(store)

        :ok
    end
  end

  @doc "Reads the newest matching versions from the current group and loose storage."
  @spec fetch(Blob.t(), term(), keyword()) :: [Trace.t()]
  def fetch(%Blob{} = store, name, opts \\ []) do
    loose = Trace.fetch(store, name, opts)

    case context(store) do
      nil ->
        loose

      state ->
        name_hash = Blob.term_digest(name)

        if MapSet.member?(state.pending_names, name_hash),
          do: flush!(store)

        {indexes, state} = indexes(context(store))
        Process.put(@context, state)
        limit = Keyword.get(opts, :limit, :all)

        packed =
          indexes
          |> Enum.flat_map(fn {path, {blob, entries}, mtime} ->
            for {observed, version, offset, size, digest, keep} <- Map.get(entries, name_hash, []) do
              %{
                path: path,
                mtime: mtime,
                refresh: Blob.refresh_interval(store),
                observed: observed,
                version: version,
                blob: blob,
                offset: offset,
                size: size,
                digest: digest,
                keep: keep
              }
            end
          end)

        loose =
          Enum.map(loose, fn trace ->
            trace
            |> Map.put(:observed, Blob.term_digest(trace.deps))
            |> Map.put(:version, loose_version(trace.path))
          end)

        (packed ++ loose)
        |> Enum.group_by(& &1.observed)
        |> Enum.map(fn {_observed, versions} -> Enum.max_by(versions, & &1.version) end)
        |> Enum.sort_by(&{&1.mtime, &1.version}, :desc)
        |> history(store)
        |> decode_records(store, name, limit)
    end
  end

  defp context(store) do
    case Process.get(@context) do
      %{root: root} = state when root == store.root -> state
      _ -> nil
    end
  end

  defp flush!(store) do
    state = context(store)

    if map_size(state.pending) > 0 do
      {records, {entries, _offset, refs}} =
        state.pending
        |> Enum.sort()
        |> Enum.map_reduce({%{}, 0, MapSet.new()}, fn
          {{name, observed}, {bytes, {_time, digest} = version, refs, keep}},
          {entries, offset, all_refs} ->
            entry = {observed, version, offset, byte_size(bytes), digest, keep}
            entries = Map.update(entries, name, [entry], &[entry | &1])

            {bytes,
             {entries, offset + byte_size(bytes), MapSet.union(all_refs, MapSet.new(refs))}}
        end)

      # Publish the payload before its index, which is its GC root.
      {:ok, blob} = Blob.put(store, records)
      index = {:roux_trace_pack, 1, state.group, blob, entries, Enum.sort(refs)}
      {digest, bytes} = Blob.encode_term(index)
      path = Path.join(state.dir, digest)
      :ok = RawIO.mkdir_p(state.dir)
      :ok = Blob.install(store, path, bytes)
      cached = Map.put(state.indexes, path, {blob, entries})

      Process.put(@context, %{
        state
        | pending: %{},
          pending_names: MapSet.new(),
          bytes: 0,
          indexes: cached,
          listing: nil
      })
    end

    :ok
  end

  defp indexes(%{lookup: :snapshot, listing: listing} = state) when is_list(listing),
    do: {listing, state}

  defp indexes(state) do
    {found, cached} =
      Enum.map_reduce(RawIO.ls(state.dir), %{}, fn file, cached ->
        path = Path.join(state.dir, file)

        with {:ok, %File.Stat{mtime: mtime}} <- RawIO.stat(path),
             {:ok, index} <- read_index(state, path, file) do
          {{path, index, mtime}, Map.put(cached, path, index)}
        else
          _ -> {nil, cached}
        end
      end)

    listing = Enum.reject(found, &is_nil/1)
    {listing, %{state | indexes: cached, listing: listing}}
  end

  defp read_index(state, path, digest) do
    case Map.fetch(state.indexes, path) do
      {:ok, index} ->
        {:ok, index}

      :error ->
        with {:ok, bytes} <- RawIO.read(path),
             true <- Blob.digest(bytes) == digest,
             {:ok, {:roux_trace_pack, 1, group, blob, entries, refs}} <- Blob.decode(bytes),
             true <- group == state.group and valid_index?(blob, entries, refs) do
          {:ok, {blob, entries}}
        else
          _ -> :miss
        end
    end
  end

  defp valid_index?(blob, entries, refs) when is_map(entries) and is_list(refs) do
    digest?(blob) and
      Enum.all?(entries, fn {name, versions} ->
        digest?(name) and is_list(versions) and Enum.all?(versions, &valid_entry?/1)
      end)
  end

  defp valid_index?(_, _, _), do: false

  defp valid_entry?({observed, {time, version_digest}, offset, size, digest, keep}) do
    digest?(observed) and is_integer(time) and time >= 0 and digest?(version_digest) and
      is_integer(offset) and offset >= 0 and is_integer(size) and size > 0 and
      digest?(digest) and (keep == :infinity or (is_integer(keep) and keep > 0))
  end

  defp valid_entry?(_), do: false

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and value =~ ~r/\A[0-9a-f]+\z/

  defp loose_version(path) do
    case Path.basename(path) |> String.split(".") do
      [_observed, time, digest] ->
        case Integer.parse(time, 16) do
          {time, ""} -> {time, digest}
          _ -> {0, ""}
        end

      _ ->
        {0, ""}
    end
  end

  defp history([], _store), do: []

  defp history(traces, store) do
    latest = Enum.max_by(traces, & &1.version)

    case Map.get(latest, :keep, :infinity) do
      :infinity ->
        traces

      keep ->
        since = System.os_time(:second) - Blob.window(store)
        {fresh, old} = Enum.split_with(traces, &(&1.mtime >= since))
        fresh ++ Enum.take(old, max(keep - length(fresh), 0))
    end
  end

  defp decode_records(traces, store, name, limit) do
    traces
    |> Stream.map(fn
      %{blob: blob, offset: offset, size: size, digest: digest} = trace ->
        with {:ok, bytes} <- Blob.get_slice(store, blob, offset, size, digest),
             {:ok, {^name, deps, value}} when is_list(deps) <- Blob.decode(bytes),
             true <- Blob.term_digest(deps) == trace.observed do
          %{
            name: name,
            deps: deps,
            value: value,
            path: trace.path,
            mtime: trace.mtime,
            refresh: trace.refresh
          }
        else
          _ -> nil
        end

      trace ->
        trace
    end)
    |> Stream.reject(&is_nil/1)
    |> then(fn stream ->
      if limit == :all, do: Enum.to_list(stream), else: Enum.take(stream, limit)
    end)
  end
end
