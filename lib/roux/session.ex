defmodule Roux.Session do
  @moduledoc """
  A database's life across runs: opened from the last run's manifest,
  committed back to it, closed.

      session =
        Roux.Session.open(
          modules: [MyTool.Graph],
          manifest: "_build/dev/my_tool.manifest",
          blob: "~/.cache/my_tool/store"
        )

      try do
        %{meta: meta} = Roux.Sources.sync(session.db, :file, files, session.sources)
        results = MyTool.Graph.run(session.db)
        Roux.Session.commit(session, meta, extra: summary(results))
      after
        Roux.Session.close(session)
      end

  `open/1` registers the modules (and languages) first and restores the
  manifest after, so a restore sees every query it may keep
  (`Roux.Lang.Manifest.restore/2`). `commit/3` writes the manifest only
  when the run changed something it would hold — an input set, an
  entry computed, the sources' metadata moved — so a run that changed
  nothing writes nothing. The manifest leaves out what the queries say
  not to keep (`Roux.Query`'s `store:` and `transient:`, with every
  entry that read a transient one) and retains in the blob store what
  it names. A small `extra` term goes beside it, readable without
  loading the manifest (`read_extra/1`): what a Mix compiler's
  `diagnostics/0` returns, say.
  """

  alias Roux.{Blob, Database, Lang, Revision, Runtime}
  alias Roux.Lang.Manifest

  @enforce_keys [:db, :manifest, :blob, :sources, :restored?, :revision, :writes]
  defstruct [:db, :manifest, :blob, :sources, :restored?, :revision, :writes]

  @typedoc """
  An open session: its database, the manifest it came from and goes to
  (nil for none), its blob store (nil for none), the sources' metadata
  the manifest held (`%{}` on a cold start), and whether it restored
  one.
  """
  @type t :: %__MODULE__{
          db: Database.t(),
          manifest: Path.t() | nil,
          blob: Blob.t() | nil,
          sources: map(),
          restored?: boolean(),
          revision: Revision.revision(),
          writes: non_neg_integer()
        }

  @doc """
  Opens a session.

  ## Options

    * `:modules` — modules of queries (`use Roux.Query`) to register
      (`Roux.Lang.register_module/2`);
    * `:languages` — languages to register (`Roux.Lang.register/2`);
    * `:manifest` — the manifest to restore from and commit to; nil (the
      default) for a session that keeps nothing;
    * `:blob` — a `Roux.Blob` store, or the root of one: where
      `store: :blob` values and code versions are kept;
    * `:force` — true to start cold, ignoring the manifest (it is still
      written on commit).
  """
  @spec open(keyword()) :: t()
  def open(opts \\ []) do
    opts =
      Keyword.validate!(opts, modules: [], languages: [], manifest: nil, blob: nil, force: false)

    blob = open_blob(Keyword.fetch!(opts, :blob))
    manifest = Keyword.fetch!(opts, :manifest)
    db = Database.new(blob: blob)

    Enum.each(Keyword.fetch!(opts, :languages), &Lang.register(db, &1))
    Enum.each(Keyword.fetch!(opts, :modules), &Lang.register_module(db, &1))

    {sources, restored?} =
      if manifest != nil and not Keyword.fetch!(opts, :force) do
        case Manifest.load(manifest) do
          {:ok, data} ->
            :ok = Manifest.restore(db, data)
            {data.sources, true}

          :error ->
            {%{}, false}
        end
      else
        {%{}, false}
      end

    %__MODULE__{
      db: db,
      manifest: manifest,
      blob: blob,
      sources: sources,
      restored?: restored?,
      revision: Revision.current(db.revision),
      writes: Database.writes(db)
    }
  end

  defp open_blob(nil), do: nil
  defp open_blob(%Blob{} = store), do: store
  defp open_blob(root) when is_binary(root), do: Blob.open!(root)

  @doc """
  Writes the session's manifest, with `sources` as its sources'
  metadata, when the run changed anything it holds: an input set or
  removed, an entry computed, or other sources' metadata than it
  restored. A session that restored nothing always writes. Returns
  whether it wrote, and the session as committed: committing it again
  writes only what changed since.

  ## Options

    * `:extra` — a small term to keep beside the manifest
      (`read_extra/1`), written when it differs from the one there.
  """
  @spec commit(t(), map(), keyword()) :: {:written | :unchanged, t()}
  def commit(session, sources, opts \\ [])

  def commit(%__MODULE__{manifest: nil} = session, _sources, _opts), do: {:unchanged, session}

  def commit(%__MODULE__{db: db, manifest: manifest} = session, sources, opts)
      when is_map(sources) do
    opts = Keyword.validate!(opts, [:extra])

    status =
      if dirty?(session, sources) do
        :ok = Manifest.write(db, sources, manifest)
        :written
      else
        :unchanged
      end

    case Keyword.fetch(opts, :extra) do
      {:ok, extra} -> write_extra(manifest, extra)
      :error -> :ok
    end

    {status,
     %{
       session
       | sources: sources,
         restored?: true,
         revision: Revision.current(db.revision),
         writes: Database.writes(db)
     }}
  end

  defp dirty?(%__MODULE__{db: db} = session, sources) do
    not session.restored? or sources != session.sources or
      Revision.current(db.revision) != session.revision or
      Database.writes(db) != session.writes
  end

  @doc """
  The `extra` term a session committed beside the manifest at
  `manifest` (`commit/3`), or `:error` when there is none, or it does
  not decode.
  """
  @spec read_extra(Path.t()) :: {:ok, term()} | :error
  def read_extra(manifest) when is_binary(manifest) do
    with {:ok, bytes} <- File.read(extra_path(manifest)),
         {:ok, extra} <- Blob.decode(bytes) do
      {:ok, extra}
    else
      _ -> :error
    end
  end

  defp write_extra(manifest, extra) do
    if read_extra(manifest) != {:ok, extra} do
      path = extra_path(manifest)
      tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
      File.mkdir_p!(Path.dirname(path))
      File.write!(tmp, :erlang.term_to_binary(extra))
      File.rename!(tmp, path)
    end

    :ok
  end

  defp extra_path(manifest), do: manifest <> ".extra"

  @doc """
  Closes a session: drops the values the calling process cached while
  serving its queries, shuts its database down, and removes its blob
  store when it was a temporary one (`Roux.Blob.temporary/0`).
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{db: db, blob: blob}) do
    Runtime.drop_cached_values(db)
    Database.shutdown(db)

    case blob do
      %Blob{temporary?: true} -> Blob.destroy(blob)
      _ -> :ok
    end
  end

  @doc """
  The files a Mix compiler reports as its manifests for a session's
  manifest at `manifest`: the manifest and its `extra` sidecar.
  """
  @spec files(Path.t()) :: [Path.t()]
  def files(manifest), do: [manifest, extra_path(manifest)]
end
