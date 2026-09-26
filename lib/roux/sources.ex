defmodule Roux.Sources do
  @moduledoc """
  Files as inputs: `sync/5` brings an input keyed by file up to date
  with what is on disk, reading only what may have changed.

  A file whose size and modification time match the last run's (the
  metadata a session's manifest holds, `Roux.Session`) is not read — the
  staleness check Mix makes. Anything else is read and hashed, and set
  as the input: `Roux.Input.set/5`'s own equality check absorbs a file
  rewritten with the same content, so a touch or a byte-identical
  rebuild changes nothing downstream. A file written within the last
  `recent:` seconds is always read: a modification time has one-second
  granularity, and a quick edit-and-rerun can rewrite a file in the
  same second with the same size.

  Keys whose files are gone are removed from the input
  (`Roux.GC.mark_input_removed/3`).
  """

  alias Roux.{Database, GC, Input}

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @typedoc "What `sync/5` keeps of a file: the prefilter's stamp and the content's hash."
  @type meta :: %{mtime: integer(), size: non_neg_integer(), hash: term()}

  @typedoc """
  What a sync did: the metadata to keep for the next (`%{path => meta}`),
  the keys whose input changed, and the keys removed.
  """
  @type result :: %{
          meta: %{optional(Path.t()) => meta()},
          changed: [term()],
          removed: [term()]
        }

  @doc """
  Syncs `input` with the files of `files` (`%{key => path}`), given the
  metadata the last sync returned (`prior`).

  ## Options

    * `:hash` — the hash of a file's content (default `:erlang.md5/1`):
      two contents with one hash are one value;
    * `:value` — the input's value for a file, given
      `%{key: key, path: path, hash: hash, content: content}` (default
      `%{path: path, hash: hash}`);
    * `:recent` — seconds within which a file is read whatever its
      stamp (default 2).
  """
  @spec sync(Database.t(), atom(), %{optional(term()) => Path.t()}, map(), keyword()) :: result()
  def sync(%Database{} = db, input, files, prior, opts \\ []) when is_atom(input) do
    opts = Keyword.validate!(opts, hash: &:erlang.md5/1, value: &default_value/1, recent: 2)
    cutoff = System.os_time(:second) - Keyword.fetch!(opts, :recent)
    job = %{db: db, input: input, prior: prior, cutoff: cutoff, opts: opts}

    {meta, changed, gone} =
      Enum.reduce(files, {%{}, [], []}, fn {key, path}, {meta, changed, gone} ->
        case sync_one(job, key, path) do
          {:unchanged, file_meta} -> {Map.put(meta, path, file_meta), changed, gone}
          {:changed, file_meta} -> {Map.put(meta, path, file_meta), [key | changed], gone}
          :gone -> {meta, changed, [key | gone]}
        end
      end)

    # A file deleted between the listing and here is simply not part of
    # this run.
    present = Map.drop(files, gone)

    removed =
      for key <- Input.keys(db, input), not Map.has_key?(present, key) do
        :ok = GC.mark_input_removed(db, input, key)
        key
      end

    %{meta: meta, changed: Enum.sort(changed), removed: Enum.sort(removed)}
  end

  defp default_value(%{path: path, hash: hash}), do: %{path: path, hash: hash}

  defp sync_one(job, key, path) do
    case :file.read_file_info(path, [:raw, {:time, :posix}]) do
      {:ok, info} ->
        size = file_info(info, :size)
        mtime = file_info(info, :mtime)
        cutoff = job.cutoff

        case Map.get(job.prior, path) do
          %{mtime: ^mtime, size: ^size} = prior when mtime < cutoff ->
            # The metadata is keyed by path, not by key: a file new to
            # this input has metadata but no value under it, and is read.
            if Input.exists?(job.db, job.input, key),
              do: {:unchanged, prior},
              else: read_and_set(job, key, path, mtime, size)

          _ ->
            read_and_set(job, key, path, mtime, size)
        end

      {:error, _} ->
        :gone
    end
  end

  defp read_and_set(job, key, path, mtime, size) do
    case File.read(path) do
      {:ok, content} ->
        hash = job.opts[:hash].(content)
        value = job.opts[:value].(%{key: key, path: path, hash: hash, content: content})
        changed? = Input.fetch(job.db, job.input, key) != {:ok, value}
        :ok = Input.set(job.db, job.input, key, value)
        meta = %{mtime: mtime, size: size, hash: hash}
        if changed?, do: {:changed, meta}, else: {:unchanged, meta}

      {:error, _} ->
        :gone
    end
  end
end
