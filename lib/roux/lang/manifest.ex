defmodule Roux.Lang.Manifest do
  @moduledoc """
  Manifest read/write for cross-VM incremental compilation.

  Serializes database state (memo entries, entity tables, intern tables,
  revision counters) and source file metadata to disk. On the next
  `mix compile`, the manifest is loaded to restore the database to its
  previous state, enabling incremental batch compilation without a
  long-lived VM.

  ## What gets persisted

  - Input memo entries (all durabilities) — needed so unchanged files can
    be skipped entirely on warm start.
  - Derived memo entries with durability `:high` or `:medium` (`:low`
    derived entries like hover info are cheap to recompute).
  - Entity table data (identity keys, tracked fields, refcounts).
  - Intern table data (forward/reverse mappings, counter state).
  - Revision counter and durability tracking state.
  - Source file metadata (mtime, content hash) for staleness detection.

  ## Layout

  Memo entries are serialized one at a time, each to its own compressed
  binary, and the manifest holds the list of those binaries. Dumping the
  whole table into one term first copied every entry out of ETS at once
  (a second copy of everything the database holds, on the writing
  process's heap) and then compressed hundreds of megabytes in one
  `term_to_binary` call; on a 600-module project that was 17 s and the
  peak of the run's memory. Entries now cross the heap one at a time in
  both directions — `write/3` folds over the table, `restore/2` decodes
  and inserts one entry at a time — and compress at level 1, which is a
  fifth of the encode time for a fifth more bytes.

  ## Versioning

  A `@manifest_vsn` tag enables graceful migration — if the version
  doesn't match, the manifest is discarded and a full rebuild runs.
  """

  alias Roux.{Database, Entity, Intern, Memo, Revision}
  alias Roux.Memo.Entry

  @manifest_vsn 2

  @entry_opts [{:compressed, 1}]

  @typedoc "Metadata for a single source file."
  @type source_meta :: %{mtime: term(), hash: integer()}

  @typedoc "Deserialized manifest data. `memo_entries` are still encoded; see `memo_entries/1`."
  @type manifest_data :: %{
          vsn: pos_integer(),
          sources: %{String.t() => source_meta()},
          memo_entries: [binary()],
          entity_data: list(),
          intern_data: list(),
          revision: map()
        }

  @doc """
  Writes a manifest to disk.

  Serializes the database state and source metadata into a compressed
  binary using `:erlang.term_to_binary/2`.
  """
  @spec write(Database.t(), %{String.t() => source_meta()}, String.t()) :: :ok
  def write(%Database{} = db, source_metadata, path) when is_binary(path) do
    data = %{
      vsn: @manifest_vsn,
      sources: source_metadata,
      memo_entries: dump_memo_entries(db),
      entity_data: dump_entity_data(db),
      intern_data: dump_intern_data(db),
      revision: Revision.snapshot(db.revision)
    }

    binary = :erlang.term_to_binary(data, @entry_opts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, binary)
  end

  @doc """
  The memo entries a loaded manifest carries, decoded: `[{query_key, entry}]`.

  `restore/2` never builds this list — it decodes entries one at a time
  into the table — so this is for inspection.
  """
  @spec memo_entries(manifest_data()) :: [{Memo.query_key(), Entry.t()}]
  def memo_entries(%{memo_entries: encoded}), do: Enum.map(encoded, &decode_entry/1)

  @doc """
  Loads a manifest from disk.

  Returns `{:ok, data}` if the file exists and has the correct version,
  `:error` otherwise (missing file, corrupt data, version mismatch).
  """
  @spec load(String.t()) :: {:ok, manifest_data()} | :error
  def load(path) when is_binary(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, %{vsn: @manifest_vsn} = data} <- safe_decode(binary) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  @doc """
  Restores a database from manifest data.

  Populates the revision counter, memo table, entity tables, and intern
  tables from the serialized state. The database should be freshly created
  (via `Database.new/0`) before calling this.
  """
  @spec restore(Database.t(), manifest_data()) :: :ok
  def restore(%Database{} = db, data) do
    Revision.restore(db.revision, data.revision)
    restore_memo_entries(db, data.memo_entries)
    restore_entity_data(db, data.entity_data)
    restore_intern_data(db, data.intern_data)
    :ok
  end

  @doc """
  Collects mtime and content hash for a list of source file paths.
  """
  @spec source_metadata([String.t()]) :: %{String.t() => source_meta()}
  def source_metadata(paths) when is_list(paths) do
    Map.new(paths, fn path ->
      %File.Stat{mtime: mtime} = File.stat!(path)
      content = File.read!(path)
      {path, %{mtime: mtime, hash: :erlang.phash2(content)}}
    end)
  end

  # -- Private: dump helpers --

  # Dumps memo entries one at a time, each to its own binary, filtering
  # out :low durability derived queries. Input entries are always
  # persisted regardless of durability so that unchanged files can be
  # skipped entirely on warm start (the spec's "Why not just use Roux's
  # content comparison?" section).
  defp dump_memo_entries(%Database{} = db) do
    Memo.reduce_entries(db, [], fn
      {{:input, _, _}, _entry} = pair, acc -> [encode_entry(pair) | acc]
      {_key, %Entry{durability: :low}}, acc -> acc
      pair, acc -> [encode_entry(pair) | acc]
    end)
  end

  defp encode_entry({key, %Entry{} = entry}),
    do: :erlang.term_to_binary({key, entry}, @entry_opts)

  defp decode_entry(binary) when is_binary(binary), do: :erlang.binary_to_term(binary)

  # Dumps entity table data as `[{module, rows}]`.
  defp dump_entity_data(%Database{} = db) do
    db
    |> Database.entity_types()
    |> Enum.map(fn module -> {module, Entity.snapshot(db, module)} end)
  end

  # Dumps intern table data as `[{name, snapshot}]`.
  defp dump_intern_data(%Database{} = db) do
    db
    |> Database.intern_table_names()
    |> Enum.map(fn name ->
      intern = Database.intern_table(db, name)
      {name, Intern.snapshot(intern)}
    end)
  end

  # -- Private: restore helpers --

  defp restore_memo_entries(%Database{} = db, encoded) do
    Enum.each(encoded, fn binary ->
      {key, entry} = decode_entry(binary)
      Memo.put(db, key, entry)
    end)
  end

  defp restore_entity_data(%Database{} = db, entity_data) do
    Enum.each(entity_data, fn {module, rows} ->
      Entity.restore(db, module, rows)
    end)
  end

  defp restore_intern_data(%Database{} = db, intern_data) do
    Enum.each(intern_data, fn {name, snapshot} ->
      intern = Database.intern_table(db, name)
      Intern.restore(intern, snapshot)
    end)
  end

  # Safely decodes a binary, returning :error on corrupt data.
  defp safe_decode(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    ArgumentError -> :error
  end
end
