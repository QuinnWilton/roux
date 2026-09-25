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
  - Intern table data (the forward mapping, encoded, and counter state;
    the reverse mapping is rebuilt when the table is first used — see
    `Roux.Intern.encode_snapshot/1`).
  - Revision counter and durability tracking state.
  - Source file metadata (mtime, content hash) for staleness detection.

  ## Layout (format 4)

  A manifest is a header and a payload:

      <<"ROUXMNFT", format::32, crc32(payload)::32, payload::binary>>

  The payload is one uncompressed `term_to_binary/1` of the manifest
  data. What makes it fast to load is what that term holds: each memo
  entry's value is already a binary of its own (the external term
  format, compressed at level 1 — `Roux.Memo.persisted/2`), and so is
  each intern table's forward rows (`Roux.Intern.encode_snapshot/1`).
  Decoding the payload decodes keys, dependencies and revisions, and
  copies those binaries without looking inside them. `restore/2` inserts
  the memo entries with their values still encoded and leaves the intern
  rows pending: a value is decoded by the first read that needs it, and
  an intern table loads on its first miss. A warm run reads a handful of
  values and no interned symbol, so it pays for almost none of it; on a
  350-module scry project, loading and restoring the manifest went from
  300 ms to under 20.

  Writing is the same in reverse. A value restored from the last
  manifest and never replaced goes back out in the encoding it came in
  with, and an intern table nothing used hands back its encoded rows, so
  a run only encodes what it recomputed.

  ## Integrity

  The header's CRC-32 covers the payload. `load/1` checks it before
  decoding the payload, and the decoded term's shape before returning
  it, so a truncated or corrupted file is refused as a whole, never
  partly read; the values decoded later are bytes the checksum covered. `write/3` writes a
  temporary file beside the manifest and renames it over the old one:
  a reader sees the old manifest or the new one, and a write that dies
  halfway leaves the old one in place.

  ## Versioning

  The format number in the header changes whenever the layout does; a
  manifest of any other format — including formats 1 to 3, which were a
  bare `term_to_binary/2` of the data with the version inside — is
  refused, and the caller rebuilds from scratch.
  """

  alias Roux.{Database, Entity, Intern, Memo, Revision}
  alias Roux.Memo.Entry

  @magic "ROUXMNFT"
  @format 4

  @typedoc "Metadata for a single source file."
  @type source_meta :: %{mtime: term(), hash: integer()}

  @typedoc """
  Deserialized manifest data. The memo entries' values and the intern
  tables' rows are still encoded; see `memo_entries/1`.
  """
  @type manifest_data :: %{
          vsn: pos_integer(),
          sources: %{String.t() => source_meta()},
          memo_entries: [Memo.persisted()],
          entity_data: [{module(), list()}],
          intern_data: [{atom(), Intern.encoded_snapshot()}],
          revision: map()
        }

  @doc """
  Writes a manifest to disk, atomically: the file at `path` is the old
  manifest or the new one, never part of either.

  Values and intern rows restored from the last manifest and not
  replaced since are written in the encoding they came in with.
  """
  @spec write(Database.t(), %{String.t() => source_meta()}, String.t()) :: :ok
  def write(%Database{} = db, source_metadata, path) when is_binary(path) do
    {payload, crc} = isolated(fn -> encode(db, source_metadata) end)
    File.mkdir_p!(Path.dirname(path))
    write_atomically!(path, [@magic, <<@format::32, crc::32>>, payload])
  end

  defp encode(db, source_metadata) do
    payload =
      :erlang.term_to_binary(%{
        sources: source_metadata,
        memo_entries: Memo.persisted(db, &persist?/2),
        entity_data: dump_entity_data(db),
        intern_data: dump_intern_data(db),
        revision: Revision.snapshot(db.revision)
      })

    {payload, :erlang.crc32(payload)}
  end

  # Runs `fun` in a process of its own and hands back its result.
  #
  # Encoding copies every recomputed value out of ETS and builds an
  # encoding of it: a burst of garbage that, on the caller's heap, sets
  # off collections of everything else the caller holds — a compiler's
  # runner holds a lot. On a 350-module scry project that was half the
  # cost of writing (390 ms against 190 ms in a fresh process). The
  # result crosses back as a binary, by reference. Monitored rather than
  # linked, so a caller that traps exits gets no `:EXIT` message; what
  # `fun` raises is raised again here.
  defp isolated(fun) do
    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        exit({__MODULE__, result})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {__MODULE__, {:ok, value}}} ->
        value

      {:DOWN, ^ref, :process, ^pid, {__MODULE__, {:raised, kind, reason, stacktrace}}} ->
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  @doc """
  The memo entries a loaded manifest carries, decoded: `[{query_key, entry}]`.

  `restore/2` never decodes the values — each is decoded by the first
  read that needs it — so this is for inspection.
  """
  @spec memo_entries(manifest_data()) :: [{Memo.query_key(), Entry.t()}]
  def memo_entries(%{memo_entries: persisted}), do: Enum.map(persisted, &Memo.decode_persisted/1)

  @doc """
  Loads a manifest from disk.

  Returns `{:ok, data}` for a manifest of this format whose checksum and
  shape hold, `:error` otherwise (missing file, another format, a
  truncated or corrupted file).
  """
  @spec load(String.t()) :: {:ok, manifest_data()} | :error
  def load(path) when is_binary(path) do
    with {:ok, binary} <- File.read(path),
         <<@magic, @format::32, crc::32, payload::binary>> <- binary,
         ^crc <- :erlang.crc32(payload),
         {:ok, data} <- decode_payload(payload) do
      {:ok, Map.put(data, :vsn, @format)}
    else
      _ -> :error
    end
  end

  @doc """
  Restores a database from manifest data.

  Populates the revision counter, memo table, entity tables, and intern
  tables from the serialized state, leaving memo values and intern rows
  encoded until they are first used (see "Layout"). The database should
  be freshly created (via `Database.new/0`) before calling this.
  """
  @spec restore(Database.t(), manifest_data()) :: :ok
  def restore(%Database{} = db, data) do
    Revision.restore(db.revision, data.revision)
    :ok = Memo.restore_persisted(db, data.memo_entries)
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

  # Input entries are always persisted regardless of durability so that
  # unchanged files can be skipped entirely on warm start (the spec's
  # "Why not just use Roux's content comparison?" section); derived
  # entries only above :low.
  defp persist?({:input, _, _}, _durability), do: true
  defp persist?(_key, :low), do: false
  defp persist?(_key, _durability), do: true

  # Dumps entity table data as `[{module, rows}]`.
  defp dump_entity_data(%Database{} = db) do
    db
    |> Database.entity_types()
    |> Enum.map(fn module -> {module, Entity.snapshot(db, module)} end)
  end

  # Dumps intern table data as `[{name, encoded_snapshot}]`.
  defp dump_intern_data(%Database{} = db) do
    db
    |> Database.intern_table_names()
    |> Enum.map(fn name ->
      intern = Database.intern_table(db, name)
      {name, Intern.encode_snapshot(intern)}
    end)
  end

  # A unique name beside the target, so concurrent writers never share
  # one, then a rename: atomic within a file system.
  defp write_atomically!(path, iodata) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    try do
      File.write!(tmp, iodata)
      File.rename!(tmp, path)
    rescue
      exception ->
        _ = File.rm(tmp)
        reraise exception, __STACKTRACE__
    end
  end

  # -- Private: restore helpers --

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

  # Decodes a checksummed payload, refusing any term that is not manifest
  # data of this format: restoring it would raise midway, or worse,
  # restore something else.
  defp decode_payload(payload) do
    data = :erlang.binary_to_term(payload)
    if valid?(data), do: {:ok, data}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp valid?(%{
         sources: sources,
         memo_entries: memo_entries,
         entity_data: entity_data,
         intern_data: intern_data,
         revision: %{counter: _, high: _, medium: _, low: _} = revision
       })
       when is_map(sources) and is_list(memo_entries) and is_list(entity_data) and
              is_list(intern_data) do
    Enum.all?(Map.values(revision), &(is_integer(&1) and &1 >= 0)) and
      Enum.all?(memo_entries, &persisted_entry?/1) and
      Enum.all?(entity_data, &match?({module, rows} when is_atom(module) and is_list(rows), &1)) and
      Enum.all?(intern_data, &intern_snapshot?/1)
  end

  defp valid?(_data), do: false

  defp persisted_entry?({_key, hash, changed_at, verified_at, deps, durability, outputs, encoded})
       when is_integer(hash) and is_integer(changed_at) and is_integer(verified_at) and
              is_list(deps) and is_atom(durability) and is_list(outputs) and is_binary(encoded),
       do: true

  defp persisted_entry?(_entry), do: false

  defp intern_snapshot?({name, %{version: 3, forward: forward, counter: counter}})
       when is_atom(name) and is_binary(forward) and is_integer(counter) and counter >= 0,
       do: true

  defp intern_snapshot?(_snapshot), do: false
end
