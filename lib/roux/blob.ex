defmodule Roux.Blob do
  @moduledoc """
  A content-addressed store on disk, safe to share between OS processes:
  large values kept by digest, an action cache, verifying traces, and
  scratch directories, with a garbage collector that never takes what a
  reader is using.

      {:ok, store} = Roux.Blob.open("~/.cache/my_tool/store")
      {:ok, digest} = Roux.Blob.put_term(store, big_value)
      {:ok, ^big_value} = Roux.Blob.get_term(store, digest)

  ## Layout

  A store is a directory:

    * `FORMAT` — the layout's version; a store of another is refused;
    * `cas/<aa>/<digest>` — content-addressed entries (`put/2`,
      `adopt/2`, `get/2`, `link/3`), named by the SHA-256 of their bytes
      in lowercase hex, `aa` its first two digits;
    * `ac/<aa>/<key digest>` — the action cache (`remember/3`,
      `recall/2`): a term stored under any key;
    * `traces/<name digest>/<trace digest>` — verifying traces
      (`Roux.Blob.Trace`);
    * `roots/<owner digest>` — the digests an owner keeps alive
      (`retain/3`), a manifest's among them;
    * `scratch/<os pid>-<n>/` — a directory per use (`scratch/2`);
    * `tmp/` — files being written; `trash/` — entries being removed.

  ## Entries

  An entry is immutable. It is written under a name of its own in
  `tmp/` and renamed into place, so a reader finds it whole or not at
  all, and two writers of one entry (same bytes) both succeed. CAS
  entries are read-only on disk: a hard link to one (`link/3`) shares
  its inode, and a program writing into the link would write into the
  store. A reader that finds an entry gone, or not holding what its name
  says, takes it for a miss (and a corrupt one is taken out of its name,
  so the next write replaces it).

  ## Collection

  `gc/2` marks from the live roots — every owner's retained digests
  (`retain/3`), and the digests named by action-cache entries and
  traces used recently — and sweeps what is left and older than a grace
  period. An entry is renamed aside before it is deleted, and put back
  when it was touched meanwhile: a `put/2` of bytes already there, or a
  `recall/2`, touches the entry it finds. The grace period must be
  longer than the longest run between writing an entry and retaining
  it: a run's own entries are young until it retains them.
  """

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @enforce_keys [:root]
  defstruct [:root, temporary?: false]

  @typedoc "A store: its root directory."
  @type t :: %__MODULE__{root: Path.t(), temporary?: boolean()}

  @typedoc "An entry's name: the SHA-256 of its bytes, lowercase hex."
  @type digest :: String.t()

  @format "roux-blob 1\n"

  # Level 1: a fifth of the default level's encode time for a fifth more
  # bytes (the manifest's trade, `Roux.Memo`).
  @term_opts [:deterministic, {:compressed, 1}]

  @day 24 * 60 * 60

  # -- Opening --

  @doc """
  Opens the store at `root`, creating it when it is not there. Refuses
  a directory holding a store of another layout (`FORMAT`).
  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, {:format, String.t()} | File.posix()}
  def open(root) when is_binary(root) do
    root = Path.expand(root)
    format = Path.join(root, "FORMAT")

    case File.read(format) do
      {:ok, @format} ->
        {:ok, %__MODULE__{root: root}}

      {:ok, other} ->
        {:error, {:format, other}}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(Path.join(root, "tmp")),
             :ok <- install_file(root, format, @format) do
          open(root)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Opens the store at `root` (`open/1`), raising on failure."
  @spec open!(Path.t()) :: t()
  def open!(root) do
    case open(root) do
      {:ok, store} ->
        store

      {:error, {:format, found}} ->
        raise Roux.Blob.FormatError, root: root, found: found

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open blob store", path: root
    end
  end

  @doc """
  A store of its own in the system's temporary directory, for a run that
  keeps nothing: `destroy/1` removes it.
  """
  @spec temporary() :: t()
  def temporary do
    root =
      Path.join(
        System.tmp_dir!(),
        "roux-blob-#{:os.getpid()}-#{System.unique_integer([:positive])}"
      )

    %{open!(root) | temporary?: true}
  end

  @doc "Removes a store and everything in it."
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{root: root}) do
    File.rm_rf!(root)
    :ok
  end

  # -- CAS --

  @doc """
  Stores `data` and returns its digest. Bytes already stored are not
  written again; their entry is touched, so a collection in progress
  keeps it.
  """
  @spec put(t(), iodata()) :: {:ok, digest()} | {:error, File.posix()}
  def put(%__MODULE__{} = store, data) do
    data = IO.iodata_to_binary(data)
    put_encoded(store, digest(data), data)
  end

  defp put_encoded(store, digest, data) do
    path = path(store, digest)

    if present?(path, byte_size(data)) do
      {:ok, digest}
    else
      with :ok <- mkdir(Path.dirname(path)),
           :ok <- install_file(store.root, path, data, 0o444) do
        {:ok, digest}
      end
    end
  end

  @doc """
  Stores `term`, encoded deterministically (`encode_term/1`), and
  returns its digest.
  """
  @spec put_term(t(), term()) :: {:ok, digest()} | {:error, File.posix()}
  def put_term(%__MODULE__{} = store, term) do
    {digest, encoded} = encode_term(term)
    put_encoded(store, digest, encoded)
  end

  @doc """
  Stores `encoded` under `digest`, both as `encode_term/1` gave them:
  for a caller that encoded a term to compare digests and keeps it.
  """
  @spec put_encoded_term(t(), digest(), binary()) :: {:ok, digest()} | {:error, File.posix()}
  def put_encoded_term(%__MODULE__{} = store, digest, encoded)
      when is_binary(digest) and is_binary(encoded),
      do: put_encoded(store, digest, encoded)

  @doc """
  `term` as `put_term/2` stores it, and the digest it is stored under:
  equal terms encode to equal bytes, so two digests compare values.
  """
  @spec encode_term(term()) :: {digest(), binary()}
  def encode_term(term) do
    encoded = :erlang.term_to_binary(term, @term_opts)
    {digest(encoded), encoded}
  end

  @doc """
  Moves the file at `path` into the store, by rename (the file must be on
  the store's file system; across file systems it is copied), and
  returns its digest. The file is gone from `path` afterwards.
  """
  @spec adopt(t(), Path.t()) :: {:ok, digest()} | {:error, File.posix()}
  def adopt(%__MODULE__{} = store, path) do
    with {:ok, digest} <- file_digest(path),
         target = path(store, digest),
         :ok <- mkdir(Path.dirname(target)),
         :ok <- File.chmod(path, 0o444),
         :ok <- move(store, path, target) do
      {:ok, digest}
    end
  end

  defp move(store, path, target) do
    case File.rename(path, target) do
      :ok ->
        :ok

      {:error, :exdev} ->
        staging = staging(store.root)

        with :ok <- File.cp(path, staging),
             :ok <- File.chmod(staging, 0o444),
             :ok <- File.rename(staging, target) do
          File.rm(path)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  The bytes stored under `digest`, or `:miss` when there are none — gone,
  or not what the digest names (the entry is then taken out of its name,
  so the next write replaces it).
  """
  @spec get(t(), digest()) :: {:ok, binary()} | :miss
  def get(%__MODULE__{} = store, digest) when is_binary(digest) do
    path = path(store, digest)

    case File.read(path) do
      {:ok, data} ->
        if digest(data) == digest do
          {:ok, data}
        else
          evict(store, path)
          :miss
        end

      {:error, _} ->
        :miss
    end
  end

  @doc """
  The term stored under `digest` (`put_term/2`), or `:miss` — including
  for bytes that do not decode as a term (read with `:safe`, which
  refuses to create atoms).
  """
  @spec get_term(t(), digest()) :: {:ok, term()} | :miss
  def get_term(%__MODULE__{} = store, digest) do
    with {:ok, data} <- get(store, digest) do
      decode(data)
    end
  end

  @doc """
  The bytes stored under `digest`, raising `Roux.Blob.MissingError`
  when there are none.
  """
  @spec fetch!(t(), digest()) :: binary()
  def fetch!(%__MODULE__{} = store, digest) do
    case get(store, digest) do
      {:ok, data} -> data
      :miss -> raise Roux.Blob.MissingError, store: store.root, digest: digest
    end
  end

  @doc "Whether `digest` is stored (without reading it)."
  @spec member?(t(), digest()) :: boolean()
  def member?(%__MODULE__{} = store, digest), do: File.regular?(path(store, digest))

  @doc """
  Makes `dest` name the entry of `digest`: a hard link, or a copy when
  `dest` is on another file system — never a symbolic link, which a
  collection could leave dangling. The linked file is read-only.
  """
  @spec link(t(), digest(), Path.t()) :: :ok | {:error, :missing | File.posix()}
  def link(%__MODULE__{} = store, digest, dest) do
    source = path(store, digest)

    case File.ln(source, dest) do
      :ok ->
        :ok

      {:error, :enoent} ->
        if File.exists?(source), do: {:error, :enoent}, else: {:error, :missing}

      {:error, reason} when reason in [:exdev, :eperm, :enotsup] ->
        case File.cp(source, dest) do
          :ok -> File.chmod(dest, 0o444)
          {:error, :enoent} -> {:error, :missing}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Where the entry of `digest` lives (whether or not it is there)."
  @spec path(t(), digest()) :: Path.t()
  def path(%__MODULE__{root: root}, <<aa::binary-size(2), _::binary>> = digest),
    do: Path.join([root, "cas", aa, digest])

  # -- Action cache --

  @doc """
  The value remembered under `key` (any term), or `:miss`. A hit touches
  the entry: a collection keeps what recently used entries name.
  """
  @spec recall(t(), term()) :: {:ok, term()} | :miss
  def recall(%__MODULE__{} = store, key) do
    path = ac_path(store, key)

    with {:ok, data} <- read_touching(path),
         {:ok, {^key, value}} <- decode(data) do
      {:ok, value}
    else
      _ -> :miss
    end
  end

  @doc "Remembers `value` under `key` (replacing what was there)."
  @spec remember(t(), term(), term()) :: :ok | {:error, File.posix()}
  def remember(%__MODULE__{} = store, key, value) do
    path = ac_path(store, key)

    with :ok <- mkdir(Path.dirname(path)) do
      install_file(store.root, path, :erlang.term_to_binary({key, value}, @term_opts))
    end
  end

  @doc """
  The value remembered under `key`, or `fun`'s, remembered — unless it
  is `:error` or `{:error, _}`: a failure is never kept, so the next
  call tries again.
  """
  @spec cached(t(), term(), (-> value)) :: value when value: var
  def cached(%__MODULE__{} = store, key, fun) when is_function(fun, 0) do
    case recall(store, key) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()

        case value do
          :error -> :ok
          {:error, _} -> :ok
          _ -> _ = remember(store, key, value)
        end

        value
    end
  end

  defp ac_path(%__MODULE__{root: root}, key) do
    <<aa::binary-size(2), _::binary>> = name = term_digest(key)
    Path.join([root, "ac", aa, name])
  end

  # -- Scratch --

  @doc """
  Runs `fun` with a directory of its own under the store (so on its file
  system: what `fun` writes there can be `adopt/2`ed, and entries
  `link/3`ed in), removed when `fun` returns or raises. A directory
  whose owner died without removing it is collected after a day.
  """
  @spec scratch(t(), (Path.t() -> result)) :: result when result: var
  def scratch(%__MODULE__{root: root}, fun) when is_function(fun, 1) do
    dir = Path.join([root, "scratch", "#{:os.getpid()}-#{System.unique_integer([:positive])}"])
    :ok = mkdir(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end

  # -- Roots --

  @doc """
  Makes `digests` the entries `owner` keeps alive, replacing what it
  kept before: a collection sweeps none of them. An owner is any term;
  an owner that is a string is a path (a manifest's), and is dropped by
  the collection once nothing is at that path.
  """
  @spec retain(t(), term(), [digest()]) :: :ok | {:error, File.posix()}
  def retain(%__MODULE__{root: root}, owner, digests) when is_list(digests) do
    dir = Path.join(root, "roots")

    with :ok <- mkdir(dir) do
      data = :erlang.term_to_binary({owner, Enum.uniq(digests)}, @term_opts)
      install_file(root, Path.join(dir, term_digest(owner)), data)
    end
  end

  @doc "Forgets what `owner` kept alive (`retain/3`)."
  @spec release(t(), term()) :: :ok
  def release(%__MODULE__{root: root}, owner) do
    _ = File.rm(Path.join([root, "roots", term_digest(owner)]))
    :ok
  end

  # -- Collection --

  @typedoc """
  Options of `gc/2`:

    * `:grace` — seconds an unmarked entry is kept after it was last
      written or touched (default a day);
    * `:keep` — seconds an action-cache entry or trace is kept after it
      was last used, and counts as a root (default a week).
  """
  @type gc_option :: {:grace, non_neg_integer()} | {:keep, non_neg_integer()}

  @typedoc "What a collection did."
  @type gc_stats :: %{
          removed: non_neg_integer(),
          bytes: non_neg_integer(),
          kept: non_neg_integer()
        }

  @doc """
  Collects the store: marks what the live roots name (see the
  moduledoc), and removes every other entry older than the grace period,
  every action-cache entry and trace unused for longer than `keep:`, and
  scratch directories and writes a dead process left behind.
  """
  @spec gc(t(), [gc_option()]) :: gc_stats()
  def gc(%__MODULE__{root: root} = store, opts \\ []) do
    grace = Keyword.get(opts, :grace, @day)
    keep = Keyword.get(opts, :keep, 7 * @day)
    now = System.os_time(:second)

    {pointers, stale_pointers} = pointers(store, now - keep)
    marked = MapSet.union(root_digests(store), pointers)

    removed =
      for aa <- ls(Path.join(root, "cas")),
          name <- ls(Path.join([root, "cas", aa])),
          not MapSet.member?(marked, name),
          path = Path.join([root, "cas", aa, name]),
          {:ok, size} <- [sweep(store, path, now - grace)],
          do: size

    swept_pointers =
      for path <- stale_pointers, {:ok, size} <- [sweep(store, path, now - keep)], do: size

    # What a process that died left behind: its scratch directories, its
    # writes in flight, its removals half done.
    for dir <- ["scratch", "tmp", "trash"],
        name <- ls(Path.join(root, dir)),
        path = Path.join([root, dir, name]),
        older_than?(path, now - @day),
        do: File.rm_rf(path)

    %{
      removed: length(removed) + length(swept_pointers),
      bytes: Enum.sum(removed) + Enum.sum(swept_pointers),
      kept: MapSet.size(marked)
    }
  end

  @doc """
  Collects the store (`gc/2`) when the last collection was longer than
  `every:` seconds ago (default a day) and no other process is
  collecting it; `:skipped` otherwise.
  """
  @spec maybe_gc(t(), [gc_option() | {:every, non_neg_integer()}]) :: {:ok, gc_stats()} | :skipped
  def maybe_gc(%__MODULE__{root: root} = store, opts \\ []) do
    {every, opts} = Keyword.pop(opts, :every, @day)
    now = System.os_time(:second)
    stamp = Path.join(root, "gc.stamp")
    lock = Path.join(root, "gc.lock")

    if older_than?(stamp, now - every) or not File.exists?(stamp) do
      # A lock older than an hour is a collector that died holding it.
      if older_than?(lock, now - 60 * 60), do: File.rm(lock)

      case File.open(lock, [:write, :exclusive]) do
        {:ok, file} ->
          File.close(file)

          try do
            stats = gc(store, opts)
            File.touch!(stamp)
            {:ok, stats}
          after
            File.rm(lock)
          end

        {:error, _} ->
          :skipped
      end
    else
      :skipped
    end
  end

  # The digests every live owner retains; an owner that is a path with
  # nothing at it is dead, and its roots go.
  defp root_digests(%__MODULE__{root: root}) do
    dir = Path.join(root, "roots")

    for name <- ls(dir),
        path = Path.join(dir, name),
        {:ok, data} <- [File.read(path)],
        {:ok, {owner, digests}} <- [decode(data)],
        live_owner?(owner, path),
        digest <- digests,
        into: MapSet.new(),
        do: digest
  end

  defp live_owner?(owner, path) when is_binary(owner) do
    if File.exists?(owner) do
      true
    else
      File.rm(path)
      false
    end
  end

  defp live_owner?(_owner, _path), do: true

  # The digests named by the action-cache entries and traces used since
  # `since`, and the ones unused since then.
  defp pointers(%__MODULE__{root: root}, since) do
    files =
      for kind <- ["ac", "traces"],
          dir <- ls(Path.join(root, kind)),
          name <- ls(Path.join([root, kind, dir])),
          do: Path.join([root, kind, dir, name])

    Enum.reduce(files, {MapSet.new(), []}, fn path, {marked, stale} ->
      if older_than?(path, since) do
        {marked, [path | stale]}
      else
        case File.read(path) do
          {:ok, data} -> {digests_in(data, marked), stale}
          {:error, _} -> {marked, stale}
        end
      end
    end)
  end

  # Every binary in a stored term that has a digest's shape: a pointer
  # names its blobs however it holds them.
  defp digests_in(data, marked) do
    case decode(data) do
      {:ok, term} -> collect_digests(term, marked)
      :miss -> marked
    end
  end

  defp collect_digests(<<_::binary-size(64)>> = bin, acc) do
    if hex?(bin), do: MapSet.put(acc, bin), else: acc
  end

  defp collect_digests([head | tail], acc), do: collect_digests(tail, collect_digests(head, acc))

  defp collect_digests(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect_digests(acc)

  defp collect_digests(map, acc) when is_map(map),
    do: :maps.fold(fn k, v, acc -> collect_digests(v, collect_digests(k, acc)) end, acc, map)

  defp collect_digests(_other, acc), do: acc

  defp hex?(bin), do: bin |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))

  # Removes `path` unless it was written or touched since `since`:
  # renamed aside first, so a reader finds it whole or not at all, and
  # put back when a touch came between the look and the rename.
  defp sweep(%__MODULE__{root: root}, path, since) do
    with true <- older_than?(path, since),
         {:ok, %File.Stat{size: size}} <- File.stat(path),
         aside = staging(root, "trash"),
         :ok <- mkdir(Path.dirname(aside)),
         :ok <- File.rename(path, aside) do
      if older_than?(aside, since) do
        File.rm(aside)
        {:ok, size}
      else
        # Touched meanwhile: back under its name, unless a writer put the
        # same bytes there again (then this copy goes).
        _ = File.ln(aside, path)
        File.rm(aside)
        :kept
      end
    else
      _ -> :kept
    end
  end

  # -- Helpers --

  @doc false
  # SHA-256 of `data`, lowercase hex: every name in the store.
  @spec digest(binary()) :: digest()
  def digest(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  @doc false
  # The name of a term used as a key.
  @spec term_digest(term()) :: digest()
  def term_digest(term), do: digest(:erlang.term_to_binary(term, [:deterministic]))

  @doc false
  @spec decode(binary()) :: {:ok, term()} | :miss
  def decode(data) do
    {:ok, :erlang.binary_to_term(data, [:safe])}
  rescue
    ArgumentError -> :miss
  end

  defp file_digest(path) do
    case File.open(path, [:read, :raw, :binary, {:read_ahead, 1_048_576}]) do
      {:ok, device} ->
        try do
          {:ok, device |> hash_device(:crypto.hash_init(:sha256)) |> hex()}
        after
          File.close(device)
        end

      {:error, _} = error ->
        error
    end
  end

  defp hash_device(device, hash) do
    case :file.read(device, 1_048_576) do
      {:ok, data} -> hash_device(device, :crypto.hash_update(hash, data))
      :eof -> :crypto.hash_final(hash)
    end
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  # Whether `path` holds `size` bytes, touching it: a present entry is
  # one a collection must now keep.
  defp present?(path, size) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: ^size}} -> touch(path) == :ok
      _ -> false
    end
  end

  @doc false
  # One change of the entry's times: it finds the entry or fails, and
  # never makes one (`File.touch/1` would create an empty file, which a
  # reader would then take for an entry).
  @spec touch(Path.t()) :: :ok | {:error, File.posix()}
  def touch(path) do
    now = System.os_time(:second)
    :file.write_file_info(path, file_info(mtime: now, atime: now), [{:time, :posix}])
  end

  defp read_touching(path) do
    case touch(path) do
      :ok -> File.read(path)
      {:error, _} = error -> error
    end
  end

  defp evict(%__MODULE__{root: root}, path) do
    aside = staging(root, "trash")

    with :ok <- mkdir(Path.dirname(aside)),
         :ok <- File.rename(path, aside) do
      File.rm(aside)
    end

    :ok
  end

  # Written under a name of its own in `tmp/`, then renamed into place.
  defp install_file(root, path, data, mode \\ nil) do
    staging = staging(root)

    result =
      with :ok <- File.write(staging, data),
           :ok <- if(mode, do: File.chmod(staging, mode), else: :ok) do
        File.rename(staging, path)
      end

    if result != :ok, do: File.rm(staging)
    result
  end

  defp staging(root, dir \\ "tmp"),
    do: Path.join([root, dir, "#{:os.getpid()}-#{System.unique_integer([:positive])}"])

  defp older_than?(path, since) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime < since
      {:error, _} -> false
    end
  end

  # One `mkdir`, and the parents only when it says they are missing: most
  # of the time the directory, or its parent, is there already.
  defp mkdir(dir) do
    case File.mkdir(dir) do
      :ok ->
        :ok

      {:error, :eexist} ->
        :ok

      {:error, :enoent} ->
        case File.mkdir_p(dir) do
          :ok -> :ok
          {:error, :eexist} -> :ok
          error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end
end
