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
    * `scratch/<os pid>.<token>-<n>/` — a directory per use (`scratch/2`),
      named after the OS process and a token of its VM's own;
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

  ## Trust

  A store has the manifest's trust model: its files were written by this
  tool, for this user, on this machine. Terms are decoded as the
  manifest decodes them — without `:safe`, so a term naming an atom the
  VM has not created yet (a function name in a stored finding) decodes
  in a fresh VM instead of missing. What makes that trust good is who
  can write the files, and `open/1` checks exactly that: it refuses a
  root, or a `FORMAT` file, that the current OS user does not own or
  that is writable by its group or by everyone (`Roux.Blob.TrustError`).
  A symbolic link as the root is followed, and its target checked the
  same way. A root `open/1` creates is made `0700`. Bytes that do not
  decode — a truncated or corrupt file — are still a miss, never a
  crash.

  ## Raw I/O, and touches that refresh

  Every file operation of the store is raw (`Roux.Blob.IO`): it goes
  straight to the operating system from the calling process, never
  through the VM's one file server, so a fan-out of lookups
  (`Roux.Runtime.parallel/3`) runs side by side.

  A lookup that finds an entry — a `put/2` of bytes already there, a
  `recall/2` hit, a trace found (`Roux.Blob.Trace`) — refreshes its
  modification time, which is what a collection and a trace prune read
  as "in use". It does so only when that time is older than the store's
  `refresh:` interval (an hour by default, `open/2`): a warm run that
  reads the same entries again writes nothing. Recency is therefore
  known to within the interval, which is why a collection's grace and
  keep periods are never shorter than it (a shorter one is taken as the
  interval).

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

  alias Roux.Blob.IO, as: RawIO

  @refresh 60 * 60

  @enforce_keys [:root]
  defstruct [:root, temporary?: false, refresh: @refresh]

  @typedoc """
  A store: its root directory, whether `temporary/0` made it, and the
  interval within which a hit leaves an entry's modification time alone
  (see "Raw I/O, and touches that refresh").
  """
  @type t :: %__MODULE__{root: Path.t(), temporary?: boolean(), refresh: non_neg_integer()}

  @typedoc "An entry's name: the SHA-256 of its bytes, lowercase hex."
  @type digest :: String.t()

  @format "roux-blob 1\n"

  # Level 1: a fifth of the default level's encode time for a fifth more
  # bytes (the manifest's trade, `Roux.Memo`).
  @term_opts [:deterministic, {:compressed, 1}]

  @day 24 * 60 * 60

  # -- Opening --

  @doc """
  Opens the store at `root`, creating it (mode `0700`) when it is not
  there. Refuses a directory holding a store of another layout
  (`FORMAT`), and one another user could have written: see "Trust".

  ## Options

    * `:refresh` — seconds within which a hit leaves an entry's
      modification time alone (default an hour; see "Raw I/O, and
      touches that refresh").
  """
  @spec open(Path.t(), keyword()) ::
          {:ok, t()}
          | {:error, {:format, String.t()} | Roux.Blob.TrustError.t() | File.posix()}
  def open(root, opts \\ []) when is_binary(root) do
    refresh = opts |> Keyword.validate!(refresh: @refresh) |> Keyword.fetch!(:refresh)

    unless is_integer(refresh) and refresh >= 0 do
      raise ArgumentError, ":refresh must be a non-negative integer, got: #{inspect(refresh)}"
    end

    root = Path.expand(root)
    format = Path.join(root, "FORMAT")

    with :ok <- ensure_root(root),
         :ok <- trusted(root, :directory) do
      case RawIO.read(format) do
        {:ok, contents} ->
          with :ok <- trusted(format, :regular) do
            if contents == @format,
              do: {:ok, %__MODULE__{root: root, refresh: refresh}},
              else: {:error, {:format, contents}}
          end

        {:error, :enoent} ->
          with :ok <- RawIO.mkdir_p(Path.join(root, "tmp")),
               :ok <- install_file(root, format, @format, 0o444) do
            open(root, opts)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A root that is not there is made, readable and writable by this user
  # alone; one that is there is left as it is, for `trusted/2` to judge.
  defp ensure_root(root) do
    case RawIO.lstat(root) do
      {:ok, _} ->
        :ok

      {:error, :enoent} ->
        with :ok <- RawIO.mkdir_p(Path.dirname(root)) do
          case RawIO.mkdir(root) do
            :ok -> RawIO.chmod(root, 0o700)
            {:error, :eexist} -> :ok
            error -> error
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Whether `path` is what the store needs it to be (a directory, or a
  # regular file), owned by this user and writable by no one else. A
  # symbolic root is followed and its target judged; a symbolic FORMAT
  # is refused. On Windows, whose file modes say nothing of this, every
  # path passes.
  defp trusted(path, kind) do
    if match?({:win32, _}, :os.type()) do
      :ok
    else
      with {:ok, stat} <- RawIO.lstat(path),
           {:ok, stat} <- follow(path, stat, kind) do
        judge(path, stat, kind, current_uid())
      end
    end
  end

  defp follow(path, %File.Stat{type: :symlink}, :directory), do: RawIO.stat(path)
  defp follow(_path, stat, _kind), do: {:ok, stat}

  defp judge(path, %File.Stat{type: type} = stat, kind, user) do
    cond do
      kind == :directory and type != :directory ->
        {:error, %Roux.Blob.TrustError{path: path, reason: :not_a_directory}}

      kind == :regular and type != :regular ->
        {:error, %Roux.Blob.TrustError{path: path, reason: :not_a_regular_file}}

      stat.uid != user ->
        {:error,
         %Roux.Blob.TrustError{path: path, reason: :not_owner, owner: stat.uid, user: user}}

      Bitwise.band(stat.mode, 0o022) != 0 ->
        {:error, %Roux.Blob.TrustError{path: path, reason: :writable_by_others, mode: stat.mode}}

      true ->
        :ok
    end
  end

  # The effective uid of this VM: the owner of a file it just made. Once
  # per VM.
  defp current_uid do
    case :persistent_term.get({__MODULE__, :uid}, nil) do
      nil ->
        probe =
          Path.join(
            System.tmp_dir!(),
            "roux-uid-#{:os.getpid()}-#{System.unique_integer([:positive])}"
          )

        File.write!(probe, "", [:exclusive])

        uid =
          try do
            File.stat!(probe).uid
          after
            File.rm(probe)
          end

        :persistent_term.put({__MODULE__, :uid}, uid)
        uid

      uid ->
        uid
    end
  end

  @doc "Opens the store at `root` (`open/2`), raising on failure."
  @spec open!(Path.t(), keyword()) :: t()
  def open!(root, opts \\ []) do
    case open(root, opts) do
      {:ok, store} ->
        store

      {:error, {:format, found}} ->
        raise Roux.Blob.FormatError, root: root, found: found

      {:error, %Roux.Blob.TrustError{} = error} ->
        raise error

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open blob store", path: root
    end
  end

  @doc """
  A store of its own in the system's temporary directory (mode `0700`),
  for a run that keeps nothing: `destroy/1` removes it.
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

    if present?(store, path, byte_size(data)) do
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
    with {:ok, digest} <- RawIO.hash_file(path),
         target = path(store, digest),
         :ok <- mkdir(Path.dirname(target)),
         :ok <- RawIO.chmod(path, 0o444),
         :ok <- move(store, path, target) do
      {:ok, digest}
    end
  end

  defp move(store, path, target) do
    case RawIO.rename(path, target) do
      :ok ->
        :ok

      {:error, :exdev} ->
        staging = staging(store.root)

        with :ok <- File.cp(path, staging),
             :ok <- RawIO.chmod(staging, 0o444),
             :ok <- RawIO.rename(staging, target) do
          RawIO.delete(path)
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

    case RawIO.read(path) do
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
  for bytes that do not decode as a term. Decoded as the manifest
  decodes, atoms and all (see "Trust").
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
  def member?(%__MODULE__{} = store, digest),
    do: match?({:ok, %File.Stat{type: :regular}}, RawIO.stat(path(store, digest)))

  @doc """
  Makes `dest` name the entry of `digest`: a hard link, or a copy when
  `dest` is on another file system — never a symbolic link, which a
  collection could leave dangling. The linked file is read-only.
  """
  @spec link(t(), digest(), Path.t()) :: :ok | {:error, :missing | File.posix()}
  def link(%__MODULE__{} = store, digest, dest) do
    source = path(store, digest)

    case RawIO.link(source, dest) do
      :ok ->
        :ok

      {:error, :enoent} ->
        if match?({:ok, _}, RawIO.stat(source)), do: {:error, :enoent}, else: {:error, :missing}

      {:error, reason} when reason in [:exdev, :eperm, :enotsup] ->
        case File.cp(source, dest) do
          :ok -> RawIO.chmod(dest, 0o444)
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
  The value remembered under `key` (any term), or `:miss`. A hit
  refreshes the entry (see "Raw I/O, and touches that refresh"): a
  collection keeps what recently used entries name.
  """
  @spec recall(t(), term()) :: {:ok, term()} | :miss
  def recall(%__MODULE__{} = store, key) do
    path = ac_path(store, key)

    with {:ok, %File.Stat{mtime: mtime}} <- RawIO.stat(path),
         {:ok, data} <- RawIO.read(path),
         {:ok, {^key, value}} <- decode(data) do
      refresh(store, path, mtime)
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
    dir = Path.join([root, "scratch", "#{RawIO.ospid()}-#{RawIO.unique()}"])
    :ok = mkdir(dir)

    try do
      fun.(dir)
    after
      RawIO.rm_rf(dir)
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
    _ = RawIO.delete(Path.join([root, "roots", term_digest(owner)]))
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
  scratch directories and writes a dead process left behind. A grace or
  keep period shorter than the store's refresh interval is taken as the
  interval: an entry in use may look that much older than it is.
  """
  @spec gc(t(), [gc_option()]) :: gc_stats()
  def gc(%__MODULE__{root: root, refresh: refresh} = store, opts \\ []) do
    grace = max(Keyword.get(opts, :grace, @day), refresh)
    keep = max(Keyword.get(opts, :keep, 7 * @day), refresh)
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
        do: RawIO.rm_rf(path)

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
        {:ok, data} <- [RawIO.read(path)],
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
      RawIO.delete(path)
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
        case RawIO.read(path) do
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
         {:ok, %File.Stat{size: size}} <- RawIO.stat(path),
         aside = staging(root, "trash"),
         :ok <- mkdir(Path.dirname(aside)),
         :ok <- RawIO.rename(path, aside) do
      if older_than?(aside, since) do
        RawIO.delete(aside)
        {:ok, size}
      else
        # Touched meanwhile: back under its name, unless a writer put the
        # same bytes there again (then this copy goes).
        _ = RawIO.link(aside, path)
        RawIO.delete(aside)
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
  # A stored term, or `:miss` for bytes that do not decode (truncated,
  # corrupt). Not `:safe`: the store is trusted as the manifest is, and a
  # term naming an atom this VM has not made yet must decode (see
  # "Trust").
  @spec decode(binary()) :: {:ok, term()} | :miss
  def decode(data) do
    {:ok, :erlang.binary_to_term(data)}
  rescue
    ArgumentError -> :miss
  end

  # Whether `path` holds `size` bytes, refreshing it: a present entry is
  # one a collection must now keep.
  defp present?(store, path, size) do
    case RawIO.stat(path) do
      {:ok, %File.Stat{type: :regular, size: ^size, mtime: mtime}} ->
        refresh(store, path, mtime) == :ok

      _ ->
        false
    end
  end

  # Marks an entry in use — sets its modification time to now — unless
  # it was marked within the store's refresh interval. A touch of an
  # entry gone meanwhile is an error, and makes nothing.
  defp refresh(%__MODULE__{refresh: interval}, path, mtime) do
    if System.os_time(:second) - mtime >= interval, do: touch(path), else: :ok
  end

  @doc false
  # The interval within which a hit leaves an entry alone, for traces
  # fetched with no store at hand (`Roux.Blob.Trace.find/4`).
  @spec refresh_interval(t() | nil) :: non_neg_integer()
  def refresh_interval(%__MODULE__{refresh: interval}), do: interval
  def refresh_interval(nil), do: @refresh

  @doc false
  # One change of the entry's times: it finds the entry or fails, and
  # never makes one (`File.touch/1` would create an empty file, which a
  # reader would then take for an entry).
  @spec touch(Path.t()) :: :ok | {:error, File.posix()}
  def touch(path), do: RawIO.utime(path, System.os_time(:second))

  @doc false
  # Takes the file at `path` out of the store whole: renamed aside into
  # `trash/`, then removed, so a reader finds it complete or not at all.
  # A file already gone is no error.
  @spec discard(t(), Path.t()) :: :ok
  def discard(%__MODULE__{} = store, path), do: evict(store, path)

  defp evict(%__MODULE__{root: root}, path) do
    aside = staging(root, "trash")

    with :ok <- mkdir(Path.dirname(aside)),
         :ok <- RawIO.rename(path, aside) do
      RawIO.delete(aside)
    end

    :ok
  end

  # Written under a name of its own in `tmp/`, then renamed into place.
  defp install_file(root, path, data, mode \\ nil) do
    staging = staging(root)

    result =
      with :ok <- RawIO.write(staging, data),
           :ok <- if(mode, do: RawIO.chmod(staging, mode), else: :ok) do
        RawIO.rename(staging, path)
      end

    if result != :ok, do: RawIO.delete(staging)
    result
  end

  defp staging(root, dir \\ "tmp"),
    do: Path.join([root, dir, "#{RawIO.ospid()}-#{RawIO.unique()}"])

  defp older_than?(path, since) do
    case RawIO.lstat(path) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime < since
      {:error, _} -> false
    end
  end

  # One raw `mkdir`, and the parents only when it says they are missing:
  # most of the time the directory, or its parent, is there already.
  defp mkdir(dir), do: RawIO.mkdir_p(dir)

  defp ls(dir), do: dir |> RawIO.ls() |> Enum.sort()
end
