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

  ## Layout (format 8)

  A manifest is a header and a payload:

      <<"ROUXMNFT", format::32, crc32(payload)::32, payload::binary>>

  The payload is an uncompressed ETF term. Keys and dependencies share
  dictionary IDs, and repeated paths and digests share binary references.
  Loading expands these references before validating the memo rows. Memo values
  remain separate ETF binaries, compressed at level 1 (`Roux.Memo.persisted/2`).
  Each intern table's forward rows are also encoded separately
  (`Roux.Intern.encode_snapshot/1`).

  `restore/2` inserts memo entries with their values still encoded and leaves
  intern rows pending. Values decode on their first read; intern tables load
  on their first miss. A warm run pays only for the values and tables it uses.

  Writing is the same in reverse. A value restored from the last
  manifest and never replaced goes back out in the encoding it came in
  with, and an intern table nothing used hands back its encoded rows, so
  a run only encodes what it recomputed.

  Each entry also carries its code version (`Roux.Query`) and the blob
  digests its value names (`Roux.Runtime.hold/1`).

  ## Values held by digest

  With a `Roux.Blob` store (the database's, `Roux.Database.new/1`'s
  `blob:`, or `write/4`'s), the value of a `store: :blob` query is kept
  in the store and the manifest holds its location: a large value the
  manifest need not carry, read back by the first read that needs it.
  Its early cutoff compares digests, and a value whose blob is gone is
  recomputed transparently (`Roux.Runtime`). The manifest retains physical
  value files and every artifact digest recorded by `Roux.Runtime.hold/1`,
  so the store keeps them while the manifest exists. A record's logical
  digest compares values; its pack's digest is the garbage-collection root.

  ## Integrity

  The header's CRC-32 covers the payload. `load/1` checks it before
  decoding the payload, and the decoded term's shape before returning
  it, so a truncated or corrupted file is refused as a whole, never
  partly read; the values decoded later are bytes the checksum covered. `write/3` writes a
  temporary file beside the manifest and renames it over the old one:
  a reader sees the old manifest or the new one, and a write that dies
  halfway leaves the old one in place. On some file systems (APFS) that
  replacing rename leaves the name missing for a moment, so `load/1`
  reads again, twice, before it takes a missing manifest for none: a
  run that did meet the moment starts cold, which costs time and never
  a wrong result.

  ## Versioning

  Format 8 shares keys, dependencies, code versions and binary subterms.
  Formats 5, 6 and 7 remain readable; older releases reject format 8 and rebuild.
  Format 7 added packed memo-value locations. Each packed value keeps its
  logical digest independently of its physical file and byte range. Unchanged
  locations are reused; sparse packs are compacted within a bounded write budget.
  Format 6 added code-version observations to dependency lists.
  """

  alias Roux.{Blob, Database, Dependencies, Entity, Intern, Memo, Revision}
  alias Roux.Lang.Manifest.Dictionary
  alias Roux.Memo.{Entry, Value, Writer}

  @magic "ROUXMNFT"
  @format 8
  @readable_formats [5, 6, 7, @format]

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

  An entry whose query says so is left out (`Roux.Query`'s `store:
  :none`), as is a transient entry (`transient:`) and every entry that
  read one, directly or through others. With reverse tracking, entries
  without a valid dependency proof and their readers are also omitted.

  ## Options

    * `:blob` — the `Roux.Blob` store to keep `store: :blob` values in
      (default: the database's). Without one they are written inline.
      The manifest then retains what it names in the store (see "Values
      held by digest").
  """
  @spec write(Database.t(), %{String.t() => source_meta()}, String.t(), keyword()) :: :ok
  def write(%Database{} = db, source_metadata, path, opts \\ []) when is_binary(path) do
    store = Keyword.get(opts, :blob, db.blob)
    {payload, crc, digests} = isolated(fn -> encode(db, source_metadata, store) end)
    File.mkdir_p!(Path.dirname(path))
    :ok = write_atomically!(path, [@magic, <<@format::32, crc::32>>, payload])

    case store do
      %Blob{} -> :ok = Blob.retain(store, Path.expand(path), digests)
      nil -> :ok
    end
  end

  defp encode(db, source_metadata, store) do
    entries = persisted_entries(db, store)
    :ok = Memo.cache_receipts(db, entries, store)

    payload =
      :erlang.term_to_binary(%{
        sources: source_metadata,
        memo_entries: Dictionary.encode(entries),
        entity_data: dump_entity_data(db),
        intern_data: dump_intern_data(db),
        revision: Revision.snapshot(db.revision)
      })

    {payload, :erlang.crc32(payload), named_digests(entries)}
  end

  # Every digest the entries name: held values and held blobs.
  defp named_digests(entries) do
    entries
    |> Enum.flat_map(fn {_key, _h, _c, _v, _d, _dur, _o, encoded, _code, blobs} ->
      Value.roots(encoded) ++ blobs
    end)
    |> Enum.uniq()
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
  The memo entries a loaded manifest carries, decoded: `[{query_key, entry}]`,
  values held by digest read from `store` (`:missing` without it, or when
  their blob is gone).

  `restore/2` never decodes the values — each is decoded by the first
  read that needs it — so this is for inspection.
  """
  @spec memo_entries(manifest_data(), Blob.t() | nil) :: [
          {Memo.query_key(), Entry.t() | :missing}
        ]
  def memo_entries(%{memo_entries: persisted}, store \\ nil),
    do: Enum.map(persisted, &Memo.decode_persisted(&1, store))

  @doc """
  Loads a manifest from disk.

  Returns `{:ok, data}` for a manifest of this format whose checksum and
  shape hold, `:error` otherwise (missing file, another format, a
  truncated or corrupted file).
  """
  @spec load(String.t()) :: {:ok, manifest_data()} | :error
  def load(path) when is_binary(path) do
    with {:ok, binary} <- read_settled(path),
         <<@magic, format::32, crc::32, payload::binary>> when format in @readable_formats <-
           binary,
         ^crc <- :erlang.crc32(payload),
         {:ok, data} <- decode_payload(payload, format) do
      {:ok, Map.put(data, :vsn, format)}
    else
      _ -> :error
    end
  end

  @doc false
  # A file replaced by rename may be missing for a moment (see
  # "Integrity"): read again, twice, before taking it for absent.
  @spec read_settled(Path.t(), [non_neg_integer()]) :: {:ok, binary()} | {:error, File.posix()}
  def read_settled(path, pauses \\ [1, 5]) do
    case {File.read(path), pauses} do
      {{:error, :enoent}, [pause | rest]} ->
        Process.sleep(pause)
        read_settled(path, rest)

      {result, _} ->
        result
    end
  end

  @doc """
  Restores a database from manifest data.

  Populates the revision counter, memo table, entity tables, and intern
  tables from the serialized state, leaving memo values and intern rows
  encoded until they are first used (see "Layout"). The database should
  be freshly created (via `Database.new/0`), with its queries registered,
  before calling this:

    * an entry of a query that is not registered is left out: nothing
      could re-execute it, or tell which code computed it — and so is
      every entry that read one, directly or through others, whether or
      not the manifest kept the unregistered query's own entry. Kept, it
      would hold an edge nothing can bring up to date, and its readers'
      durability checks would pass over it;
    * an entry computed by another code version than its query's
      (`Roux.Query`) is restored, and stale: it re-executes when next
      demanded, keeping its `changed_at` if its value comes back the
      same. The revision advances at `:high` once when there is any,
      since no durability check sees a code change.

  A value held by digest is read from the database's `Roux.Blob` store.
  """
  @spec restore(Database.t(), manifest_data()) :: :ok
  def restore(%Database{} = db, data), do: restore_with(db, data, &Memo.restore_persisted/2)

  @doc false
  @spec restore_new(Database.t(), manifest_data()) :: :ok
  def restore_new(%Database{} = db, data), do: restore_with(db, data, &Memo.restore_new/2)

  defp restore_with(db, data, restore_memos) do
    Revision.restore(db.revision, data.revision)
    {entries, code_moved?} = registered(db, data.memo_entries)
    :ok = restore_memos.(db, entries)
    # Restored entries already require an ordered dependency walk, including
    # code-version checks. Keep their old values proven for early cutoff.
    if code_moved?, do: Dependencies.advance(db, :high)
    restore_entity_data(db, data.entity_data)
    restore_intern_data(db, data.intern_data)
    :ok
  end

  # The entries to restore — every input's, and the entries of registered
  # queries that read no unregistered one, even transitively — and
  # whether any of them was computed by another code version than its
  # query's.
  defp registered(db, entries) do
    {verdicts, registry} =
      Enum.map_reduce(entries, %{}, fn entry, registry ->
        {own, registry} = own_verdict(db, entry, registry)
        {dangling?, registry} = reads_unregistered?(db, elem(entry, 4), registry)

        own =
          if own == :keep and code_observations_changed?(db, elem(entry, 4)),
            do: :moved,
            else: own

        {{entry, own, dangling?}, registry}
      end)

    _ = registry

    dropped =
      case for({entry, own, dangling?} <- verdicts, own == :drop or dangling?, do: elem(entry, 0)) do
        [] -> %{}
        roots -> spread(roots, readers(verdicts), %{})
      end

    kept =
      for {entry, own, _} <- verdicts, not Map.has_key?(dropped, elem(entry, 0)), do: {entry, own}

    {Enum.map(kept, &elem(&1, 0)), Enum.any?(kept, &(elem(&1, 1) == :moved))}
  end

  # An input is kept; a derived entry is dropped when its query is not
  # registered, and moved when it was computed by another code version.
  defp own_verdict(_db, {{:input, _, _}, _, _, _, _, _, _, _, _, _}, registry),
    do: {:keep, registry}

  defp own_verdict(db, {{name, _key}, _, _, _, _, _, _, _, stored, _}, registry) do
    case registration(db, name, registry) do
      {{:ok, ^stored}, registry} -> {:keep, registry}
      {{:ok, _other}, registry} -> {:moved, registry}
      {:unregistered, registry} -> {:drop, registry}
    end
  end

  defp code_observations_changed?(db, dependencies) do
    Enum.any?(dependencies, fn
      {:query_code, name, version} -> Database.code_version(db, name) != version
      {:parallel, _, members} -> code_observations_changed?(db, members)
      _ -> false
    end)
  end

  # Whether any dependency names a query that is not registered.
  defp reads_unregistered?(_db, [], registry), do: {false, registry}

  defp reads_unregistered?(db, [dep | rest], registry) do
    {unregistered?, registry} =
      Enum.reduce_while(read_keys(dep), {false, registry}, fn
        {:input, _, _}, acc ->
          {:cont, acc}

        {name, _key}, {false, registry} ->
          case registration(db, name, registry) do
            {:unregistered, registry} -> {:halt, {true, registry}}
            {{:ok, _}, registry} -> {:cont, {false, registry}}
          end
      end)

    if unregistered?, do: {true, registry}, else: reads_unregistered?(db, rest, registry)
  end

  # For each entry, the entries that read it.
  defp readers(verdicts) do
    Enum.reduce(verdicts, %{}, fn {entry, _own, _dangling?}, acc ->
      key = elem(entry, 0)

      entry
      |> elem(4)
      |> Enum.flat_map(&read_keys/1)
      |> Enum.reduce(acc, &Map.update(&2, &1, [key], fn keys -> [key | keys] end))
    end)
  end

  # A query's registration, `{:ok, code_version}` or `:unregistered`,
  # looked up once per name.
  defp registration(db, name, registry) do
    case registry do
      %{^name => registered} ->
        {registered, registry}

      %{} ->
        registered =
          if Database.query_registered?(db, name),
            do: {:ok, Database.code_version(db, name)},
            else: :unregistered

        {registered, Map.put(registry, name, registered)}
    end
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

  defp persisted_entries(db, store) do
    excluded = transient_closure(db)

    entries =
      Writer.run(store, db.blob, fn publisher ->
        Memo.persisted(
          db,
          fn key, durability, persist ->
            persist in [:inline, :blob] and persist?(key, durability) and
              not Map.has_key?(excluded, key)
          end,
          {:encoded, publisher}
        )
      end)

    entries |> relocate_blobs(db.blob, store) |> drop_missing()
  end

  defp relocate_blobs(entries, %Blob{root: root}, %Blob{root: root}), do: entries
  defp relocate_blobs(entries, _source, nil), do: entries

  defp relocate_blobs(entries, source, target) do
    missing =
      entries
      |> Enum.flat_map(&elem(&1, 9))
      |> Enum.uniq()
      |> Enum.reject(&copy_blob(source, target, &1))
      |> MapSet.new()

    Enum.map(entries, fn entry ->
      if Enum.any?(elem(entry, 9), &MapSet.member?(missing, &1)),
        do: put_elem(entry, 7, :missing),
        else: entry
    end)
  end

  defp copy_blob(source, target, digest) do
    bytes =
      case Blob.get(target, digest) do
        {:ok, _} = found -> found
        :miss -> Value.load_bytes(source, {:blob, digest})
      end

    with {:ok, bytes} <- bytes,
         {:ok, ^digest} <- Blob.put_encoded_term(target, digest, bytes) do
      true
    else
      _ -> false
    end
  end

  # A restored value can disappear before it is copied to another store or
  # compacted. Drop its readers too, just as for transient computations.
  defp drop_missing(entries) do
    case for entry <- entries, elem(entry, 7) == :missing, do: elem(entry, 0) do
      [] ->
        entries

      missing ->
        readers = readers(Enum.map(entries, &{&1, :keep, false}))
        dropped = spread(missing, readers, %{})
        Enum.reject(entries, &Map.has_key?(dropped, elem(&1, 0)))
    end
  end

  # Input entries are always persisted regardless of durability so that
  # unchanged files can be skipped entirely on warm start (the spec's
  # "Why not just use Roux's content comparison?" section); derived
  # entries only above :low.
  defp persist?({:input, _, _}, _durability), do: true
  defp persist?(_key, :low), do: false
  defp persist?(_key, _durability), do: true

  # The transient entries and everything that read one, transitively.
  # Kept, a reader would restore beside the transient value's absence,
  # pass its durability check on the next run, and serve what that value
  # led to without ever asking again.
  defp transient_closure(db) do
    case Memo.keys_persisted_as(db, :transient) ++ Memo.unproven_keys(db) do
      [] ->
        %{}

      roots ->
        readers =
          Memo.reduce_dependencies(db, %{}, fn key, deps, acc ->
            Enum.reduce(deps, acc, fn dep, acc ->
              Enum.reduce(
                read_keys(dep),
                acc,
                &Map.update(&2, &1, [key], fn ks -> [key | ks] end)
              )
            end)
          end)

        spread(roots, readers, %{})
    end
  end

  # The entries a dependency names.
  defp read_keys({:entity_field, _module, _id, _field}), do: []
  defp read_keys({:query_code, _name, _version}), do: []
  defp read_keys({:input_absent, _input, _key}), do: []
  defp read_keys({:parallel, _max, members}), do: members
  defp read_keys(key), do: [key]

  defp spread([], _readers, seen), do: seen

  defp spread([key | rest], readers, seen) do
    if Map.has_key?(seen, key),
      do: spread(rest, readers, seen),
      else: spread(Map.get(readers, key, []) ++ rest, readers, Map.put(seen, key, true))
  end

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
  defp decode_payload(payload, format) do
    data = :erlang.binary_to_term(payload)

    with {:ok, data} <- expand_dictionary(data, format),
         true <- valid?(data) do
      {:ok, data}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp expand_dictionary(%{memo_entries: encoded} = data, 8) do
    with {:ok, entries} <- Dictionary.decode(encoded),
         do: {:ok, %{data | memo_entries: entries}}
  end

  defp expand_dictionary(data, format) when format in [5, 6, 7], do: {:ok, data}
  defp expand_dictionary(_, _), do: :error

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
      Enum.all?(memo_entries, &Memo.persisted?/1) and
      Enum.all?(entity_data, &match?({module, rows} when is_atom(module) and is_list(rows), &1)) and
      Enum.all?(intern_data, &intern_snapshot?/1)
  end

  defp valid?(_data), do: false

  defp intern_snapshot?({name, %{version: 3, forward: forward, counter: counter}})
       when is_atom(name) and is_binary(forward) and is_integer(counter) and counter >= 0,
       do: true

  defp intern_snapshot?(_snapshot), do: false
end
