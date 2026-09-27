defmodule Roux.Code do
  @moduledoc """
  The code a computation runs, named by a digest: what a query's code
  version is made of (`Roux.Query`'s `code:` option).

  A computation runs the code its remote calls reach from where it
  starts. `closure/2` reads that reach from each module's import table,
  from `roots` onward, through the project and its dependencies, and
  stops at the runtime: OTP's modules and Elixir's, whose versions a
  digest carries instead, and consolidated protocols, which are the
  build's dispatch tables. `digest/2` hashes what it found, each module
  by `beam_digest/2`.

  So an edit to a module moves the digest of every root set that
  reaches it, and of no other. A call the import table does not show —
  `apply/3`, `module.fun()` on a module held in a variable — reaches
  code the walk cannot see: name what it can reach as a root of its
  own. `Roux.Code.Verify.executed/2` runs a computation with call
  counting on, for a test that checks the closure against what
  actually ran.

  ## Where code is read

  Object code comes from `:code.get_object_code/1`, which finds a
  module on the code path wherever it lives: a `.beam` file, or an
  escript's archive. A module that was compiled in memory (or
  cover-compiled) has no object code to read, and no digest can name
  it: `closure/2` returns an error naming it.

  ## Memoized per VM

  A closure and its digest are computed once per VM for each set of
  roots and options: a VM that loads new code mid-run keeps the digest
  of the code it started with (`forget/0` drops them).

  ## Kept across VMs

  With `store:`, `digest/2` keeps a digest in a `Roux.Blob` store as a
  verifying trace (`Roux.Blob.Trace`) over what computing it read: the
  stat stamp (size, modification time, inode, change time) of every
  file the walk read object code from, and the absence of every module
  it found absent. A fresh VM whose beams have not moved gets the digest
  from a few `stat` calls, reading no beam at all. A module in an
  archive — an escript's — has no stamp of its own, and is stamped by
  the archive: a fresh run of an escript verifies one `stat`. A trace is
  not kept when a file was written within the last two seconds (a stamp
  that young may not yet show a write that follows it).

  ## In an escript

  An escript's modules live in its archive, and so does Elixir's
  standard library when the escript embeds it (as `mix escript.build`
  does): Elixir's `:code.lib_dir/1` is then a path inside the escript.
  Elixir's modules are recognized by their application wherever they
  live, and everything else in the archive is code like any other.
  """

  alias Roux.Blob

  @typedoc "Where a module of a closure was read from, or `:absent` (not on the code path)."
  @type location :: Path.t() | :absent

  @typedoc """
  Options of `closure/2` and `digest/2`:

    * `:exclude` — modules left out of the closure, as a list or a
      predicate: a module whose meaning a caller keys some other way
      (argus's schema, keyed on the entries a query read of it).
    * `:follow_excluded` — whether the walk goes on through an excluded
      module to what it calls (default `true`): its callees are code
      like any other. `false` stops there.
    * `:store` — a `Roux.Blob` store to keep the digest in across VMs
      (`digest/2` only; see "Kept across VMs").
  """
  @type option ::
          {:exclude, [module()] | (module() -> boolean())}
          | {:follow_excluded, boolean()}
          | {:store, Blob.t() | nil}

  # A stamp younger than this may not yet show a write that follows it
  # within the same second.
  @recent_seconds 2

  @elixir_apps [:elixir, :eex, :ex_unit, :iex, :logger, :mix]
  @elixir_app_names Enum.map(@elixir_apps, &Atom.to_string/1)

  # -- Closure --

  @doc """
  The modules `roots` reach, sorted, each with the file its object code
  was read from, or `:absent` for a module a call names that is not on
  the code path (an optional dependency: its arrival would change what
  the call does). Runtime modules are not in it (see the moduledoc).
  """
  @spec closure([module()], [option()]) ::
          {:ok, [{module(), location()}]} | {:error, {:no_beam, module()}}
  def closure(roots, opts \\ []) when is_list(roots) do
    {exclude, follow?} = exclusion(opts)

    memo({:closure, Enum.sort(roots), exclude, follow?}, fn ->
      with {:ok, seen} <- walk(roots, %{}, exclude, follow?) do
        {:ok, located(seen)}
      end
    end)
  end

  defp located(seen) do
    seen
    |> Enum.flat_map(fn
      {mod, {:object, _bin, file}} -> [{mod, file}]
      {mod, :absent} -> [{mod, :absent}]
      {_mod, _walked_or_runtime} -> []
    end)
    |> Enum.sort()
  end

  # `seen` maps each module met to `{:object, binary, file}`, `:absent`,
  # `:runtime`, or `{:walked, file}` (excluded, followed) or `:skipped`
  # (excluded, not followed).
  defp walk([], seen, _exclude, _follow?), do: {:ok, seen}

  defp walk([mod | rest], seen, exclude, follow?) do
    if Map.has_key?(seen, mod) do
      walk(rest, seen, exclude, follow?)
    else
      case where(mod) do
        :runtime ->
          walk(rest, Map.put(seen, mod, :runtime), exclude, follow?)

        :absent ->
          walk(rest, Map.put(seen, mod, :absent), exclude, follow?)

        :no_beam ->
          {:error, {:no_beam, mod}}

        {:object, bin, file} ->
          excluded? = excluded?(exclude, mod)

          cond do
            not excluded? ->
              walk(
                callees(bin) ++ rest,
                Map.put(seen, mod, {:object, bin, file}),
                exclude,
                follow?
              )

            follow? ->
              walk(callees(bin) ++ rest, Map.put(seen, mod, {:walked, file}), exclude, follow?)

            true ->
              walk(rest, Map.put(seen, mod, :skipped), exclude, follow?)
          end
      end
    end
  end

  # The modules a beam calls into: its import table, and the external
  # funs among its literals (`&Other.fun/1` is a literal, not an import).
  defp callees(bin) do
    {:ok, {_mod, chunks}} = :beam_lib.chunks(bin, [:imports, ~c"LitT"], [:allow_missing_chunks])
    imported = for {callee, _fun, _arity} <- Keyword.fetch!(chunks, :imports), do: callee

    captured =
      case List.keyfind(chunks, ~c"LitT", 0) do
        {_, <<size::32, table::binary>>} ->
          <<_count::32, entries::binary>> = if size == 0, do: table, else: :zlib.uncompress(table)

          for <<len::32, term::binary-size(len) <- entries>>,
              mod <- external_funs(:erlang.binary_to_term(term), []),
              do: mod

        _missing ->
          []
      end

    Enum.uniq(imported ++ captured)
  end

  defp external_funs(fun, acc) when is_function(fun) do
    case :erlang.fun_info(fun, :type) do
      {:type, :external} -> [elem(:erlang.fun_info(fun, :module), 1) | acc]
      {:type, :local} -> acc
    end
  end

  defp external_funs([head | tail], acc), do: external_funs(tail, external_funs(head, acc))

  defp external_funs(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> external_funs(acc)

  defp external_funs(map, acc) when is_map(map),
    do: :maps.fold(fn k, v, acc -> external_funs(v, external_funs(k, acc)) end, acc, map)

  defp external_funs(_other, acc), do: acc

  defp excluded?(exclude, mod) when is_list(exclude), do: mod in exclude
  defp excluded?(exclude, mod) when is_function(exclude, 1), do: exclude.(mod) == true

  defp exclusion(opts) do
    exclude =
      case Keyword.get(opts, :exclude, []) do
        list when is_list(list) ->
          Enum.sort(list)

        fun when is_function(fun, 1) ->
          fun

        other ->
          raise ArgumentError,
                ":exclude must be a list of modules or a 1-arity function, got: #{inspect(other)}"
      end

    follow? =
      case Keyword.get(opts, :follow_excluded, true) do
        bool when is_boolean(bool) ->
          bool

        other ->
          raise ArgumentError, ":follow_excluded must be a boolean, got: #{inspect(other)}"
      end

    {exclude, follow?}
  end

  # A module of this project or a dependency is read from its object
  # code; OTP's and Elixir's own are covered by the runtime's version,
  # and a consolidated protocol is the build's dispatch table.
  defp where(mod) do
    case :code.which(mod) do
      :non_existing -> :absent
      :preloaded -> :runtime
      [_ | _] = path -> located(mod, List.to_string(path))
      _in_memory_or_cover_compiled -> :no_beam
    end
  end

  defp located(mod, path) do
    if runtime?(mod, path) do
      :runtime
    else
      case :code.get_object_code(mod) do
        {^mod, bin, file} -> {:object, bin, List.to_string(file)}
        :error -> :no_beam
      end
    end
  end

  defp runtime?(mod, path) do
    String.starts_with?(path, otp_root()) or under_elixir_root?(path) or
      "consolidated" in Path.split(path) or elixir_app?(mod) or elixir_app_dir?(path)
  end

  # Under the directory of Elixir's installed applications. An escript
  # that embeds Elixir has none: its `:elixir` library directory is a
  # path inside the escript's archive, and the directory above it is the
  # escript itself, whose every member would count as the runtime's.
  defp under_elixir_root?(path) do
    case elixir_root() do
      nil -> false
      root -> String.starts_with?(path, root)
    end
  end

  defp elixir_root do
    memo(:elixir_root, fn ->
      lib_dir = :elixir |> :code.lib_dir() |> List.to_string()
      if File.dir?(lib_dir), do: Path.dirname(lib_dir) <> "/"
    end)
  end

  # A beam in the `ebin` of one of Elixir's applications (`elixir/ebin`,
  # `logger-1.19.4/ebin`): Elixir's own, wherever it lives. No project
  # or dependency application can bear one of their names.
  defp elixir_app_dir?(path) do
    app = path |> Path.dirname() |> Path.dirname() |> Path.basename()
    [name | _version] = String.split(app, "-", parts: 2)
    Path.basename(Path.dirname(path)) == "ebin" and name in @elixir_app_names
  end

  # Elixir's own modules bundled into an escript live in its archive,
  # under no runtime directory: known by their application instead.
  defp elixir_app?(mod) do
    modules =
      memo(:elixir_modules, fn ->
        for app <- @elixir_apps,
            mod <- Application.spec(app, :modules) || [],
            into: MapSet.new(),
            do: mod
      end)

    MapSet.member?(modules, mod)
  end

  defp otp_root, do: List.to_string(:code.root_dir()) <> "/"

  # -- Digest --

  @doc """
  A digest of `closure/2`'s code: each module by name and
  `beam_digest/2` (or as absent), and the runtime's version
  (`runtime_version/0`). Lowercase hex.
  """
  @spec digest([module()], [option()]) :: {:ok, String.t()} | {:error, term()}
  def digest(roots, opts \\ []) when is_list(roots) do
    {store, opts} = Keyword.pop(opts, :store)
    {exclude, follow?} = exclusion(opts)
    key = {:digest, Enum.sort(roots), exclude, follow?}

    memo(key, fn ->
      case store do
        nil -> compute_digest(roots, exclude, follow?)
        %Blob{} = store -> kept_digest(store, key, roots, exclude, follow?)
      end
    end)
  end

  defp compute_digest(roots, exclude, follow?) do
    with {:ok, seen} <- walk(roots, %{}, exclude, follow?) do
      {:ok, digest_of(seen)}
    end
  end

  # A digest kept as a verifying trace over what computing it read (see
  # "Kept across VMs").
  defp kept_digest(store, key, roots, exclude, follow?) do
    name = {__MODULE__, key, runtime_version()}

    case Blob.Trace.find(store, name, &observe/1) do
      {:ok, digest} ->
        {:ok, digest}

      :miss ->
        with {:ok, seen} <- walk(roots, %{}, exclude, follow?) do
          digest = digest_of(seen)
          deps = seen |> Enum.flat_map(&trace_deps/1) |> Enum.uniq()
          if Enum.all?(deps, &trustworthy?/1), do: _ = Blob.Trace.put(store, name, deps, digest)
          {:ok, digest}
        end
    end
  end

  # What the walk read of each module it met: the file of one it read
  # (walked-through ones too: their import tables shape the closure), and
  # the absence of one it found absent. A module in an archive (an
  # escript's) is stamped by the archive: every module in it shares that
  # one stat.
  defp trace_deps({_mod, {:object, _bin, file}}), do: [file_dep(file)]
  defp trace_deps({_mod, {:walked, file}}), do: [file_dep(file)]
  defp trace_deps({mod, :absent}), do: [{{:absent, mod}, true}]
  defp trace_deps({_mod, _runtime_or_skipped}), do: []

  defp file_dep(file) do
    stamped = stamped_file(file)
    {{:file, stamped}, stamp(stamped)}
  end

  # The file whose stamp speaks for `file`: itself, or — for a member of
  # an archive, which has no stamp of its own — the archive, the nearest
  # ancestor on its path that is a regular file.
  defp stamped_file(file) do
    if type(file) == :regular, do: file, else: archive_of(file) || file
  end

  defp archive_of(path) do
    parent = Path.dirname(path)

    cond do
      parent == path -> nil
      type(parent) == :regular -> parent
      type(parent) == :directory -> nil
      true -> archive_of(parent)
    end
  end

  defp type(path) do
    case Blob.IO.stat(path) do
      {:ok, %File.Stat{type: type}} -> type
      {:error, _} -> nil
    end
  end

  defp trustworthy?({{:file, _file}, :none}), do: false

  defp trustworthy?({{:file, _file}, {_size, mtime, _inode, _ctime}}),
    do: mtime < System.os_time(:second) - @recent_seconds

  defp trustworthy?({{:absent, _mod}, true}), do: true

  defp observe({:file, file}), do: stamp(file)
  defp observe({:absent, mod}), do: :code.which(mod) == :non_existing

  # Raw: a fresh VM checks a kept digest with a stat per file, and none of
  # them waits on the VM's file server.
  defp stamp(file) do
    case Blob.IO.stat(file) do
      {:ok, %File.Stat{size: size, mtime: mtime, inode: inode, ctime: ctime}} ->
        {size, mtime, inode, ctime}

      {:error, _} ->
        :none
    end
  end

  defp digest_of(seen) do
    parts =
      seen
      |> Enum.flat_map(fn
        {mod, {:object, bin, file}} -> [{mod, {:code, module_digest(bin, file)}}]
        {mod, :absent} -> [{mod, :absent}]
        _other -> []
      end)
      |> Enum.sort()
      |> Enum.map(fn
        {mod, {:code, code}} -> Atom.to_string(mod) <> " " <> code
        {mod, :absent} -> "absent " <> Atom.to_string(mod)
      end)

    hash([runtime_version() | parts])
  end

  defp module_digest(bin, file) do
    memo({:module, file, :erlang.md5(bin)}, fn ->
      case beam_digest(bin, root: build_root(file)) do
        {:ok, digest} -> Base.encode16(digest, case: :lower)
        {:error, reason} -> raise ArgumentError, "unreadable beam #{file}: #{inspect(reason)}"
      end
    end)
  end

  @doc """
  The version of the runtime a digest covers instead of its code: the
  OTP release, the ERTS version and Elixir's version.
  """
  @spec runtime_version() :: String.t()
  def runtime_version do
    "otp #{:erlang.system_info(:otp_release)} erts #{:erlang.system_info(:version)} " <>
      "elixir #{System.version()}"
  end

  @doc "Drops every closure and digest this VM memoized."
  @spec forget() :: :ok
  def forget do
    for {{__MODULE__, _} = key, _value} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end

  # -- Beam digests --

  @never ~w(CInf Docs ExCk)
  @debug ~w(Dbgi Abst)
  @marker "$ROOT"

  @doc """
  A digest of a compiled module that names what it does, not where it
  was built.

  A beam's bytes carry the absolute path of the tree it was compiled in:
  the source file in its compile info and debug info, and — when the
  code reads `__DIR__`, `__ENV__.file` or `Application.app_dir/2` at
  compile time — in its literals too. Two worktrees at one commit build
  byte-different beams of the same code. This digest reads the chunks
  instead, with the build root taken out.

  Every chunk is hashed, in chunk-id order, except the ones that
  describe the code rather than being part of it: `CInf` (compile
  options and the source path), `Docs` (prose) and `ExCk` (the Elixir
  type checker's export table) never are; `Dbgi` and `Abst` (debug
  info) only with `debug_info: true`. `Line` stays: an edit that moves a
  line moves the digest.

  The build root is the directory holding the innermost `_build` on the
  beam's path (`build_root/1`), or `root:` for a binary. Inside the
  literal table, the attributes, the line table's file names and the
  debug info, every binary containing it — and every charlist starting
  with it — has it replaced by `$ROOT`. A fun's `OldUniq` and the `vsn`
  attribute (the default one is the module's MD5) are cleared: neither
  changes what the code computes.

  Returns the raw SHA-256, or why `:beam_lib` could not read the beam.
  """
  @spec beam_digest(Path.t() | binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def beam_digest(beam, opts \\ []) do
    debug_info? = Keyword.get(opts, :debug_info, false)

    {source, root} =
      if beam_binary?(beam),
        do: {beam, Keyword.get(opts, :root)},
        else:
          {String.to_charlist(beam), Keyword.get_lazy(opts, :root, fn -> build_root(beam) end)}

    case :beam_lib.all_chunks(source) do
      {:ok, _module, chunks} ->
        hash =
          chunks
          |> Enum.map(fn {id, data} -> {List.to_string(id), data} end)
          |> Enum.reject(fn {id, _} -> id in @never or (id in @debug and not debug_info?) end)
          |> Enum.sort()
          |> Enum.reduce(:crypto.hash_init(:sha256), fn {id, data}, hash ->
            normalized = normalize(id, data, root)

            hash
            |> :crypto.hash_update(id)
            |> :crypto.hash_update(<<byte_size(normalized)::64>>)
            |> :crypto.hash_update(normalized)
          end)
          |> :crypto.hash_final()

        {:ok, hash}

      {:error, :beam_lib, reason} ->
        {:error, reason}
    end
  end

  defp beam_binary?(<<"FOR1", _::binary>>), do: true
  defp beam_binary?(_path), do: false

  @doc """
  The directory holding the innermost `_build` on `beam`'s path, or
  `nil` when there is none.
  """
  @spec build_root(Path.t()) :: String.t() | nil
  def build_root(beam) do
    parts = beam |> Path.expand() |> Path.split()

    case parts |> Enum.with_index() |> Enum.filter(fn {p, _} -> p == "_build" end) do
      [] -> nil
      found -> parts |> Enum.take(found |> List.last() |> elem(1)) |> Path.join()
    end
  end

  @dropped [~c"ExCk", ~c"Docs"]

  @doc """
  Rebuilds `beam` without its `ExCk` and `Docs` chunks.

  Elixir rewrites a module's beam when a compile-time dependency is
  recompiled even if nothing in the module changed: `ExCk` (the type
  checker's signature cache) is regenerated, and `Docs` moves with any
  `@doc` edit. For a consumer that reads neither, two beams that differ
  only there are the same input: hash this instead of the bytes. A
  binary `:beam_lib` cannot parse comes back unchanged.
  """
  @spec canonical_beam(binary()) :: binary()
  def canonical_beam(beam) when is_binary(beam) do
    case :beam_lib.all_chunks(beam) do
      {:ok, _module, chunks} ->
        kept = Enum.reject(chunks, fn {id, _data} -> id in @dropped end)
        {:ok, rebuilt} = :beam_lib.build_module(kept)
        rebuilt

      {:error, :beam_lib, _reason} ->
        beam
    end
  end

  defp normalize(_id, data, nil = _root), do: data

  defp normalize("LitT", data, root), do: literals(data, root)
  defp normalize("Line", data, root), do: line_files(data, root)

  defp normalize("FunT", <<count::32, entries::binary>>, _root) do
    cleared =
      for <<name::32, arity::32, label::32, index::32, free::32, _old_uniq::32 <- entries>>,
        into: <<>>,
        do: <<name::32, arity::32, label::32, index::32, free::32, 0::32>>

    <<count::32, cleared::binary>>
  end

  defp normalize("Attr", data, root) do
    case decode(data) do
      {:ok, attributes} when is_list(attributes) ->
        attributes
        |> Enum.reject(&match?({:vsn, _}, &1))
        |> paths(root)
        |> :erlang.term_to_binary([:deterministic])

      _undecodable ->
        data
    end
  end

  defp normalize(id, data, root) when id in @debug do
    case decode(data) do
      {:ok, term} -> term |> paths(root) |> :erlang.term_to_binary([:deterministic])
      :error -> data
    end
  end

  defp normalize(_id, data, _root), do: data

  # A stripped beam's `Abst` is empty; hashed as it is, like any chunk
  # that is not a term.
  defp decode(data) do
    {:ok, :erlang.binary_to_term(data)}
  rescue
    ArgumentError -> :error
  end

  # `<<UncompressedSize:32, Table>>`, the table zlib-compressed unless
  # the size is 0 (OTP 28 writes it uncompressed): `<<Count:32>>` then
  # each literal as `<<Size:32, ExternalTerm>>`.
  defp literals(<<size::32, table::binary>>, root) do
    <<count::32, entries::binary>> = if size == 0, do: table, else: :zlib.uncompress(table)

    normalized =
      for <<len::32, term::binary-size(len) <- entries>>, into: <<>> do
        encoded =
          term
          |> :erlang.binary_to_term()
          |> paths(root)
          |> :erlang.term_to_binary([:deterministic])

        <<byte_size(encoded)::32, encoded::binary>>
      end

    <<count::32, normalized::binary>>
  end

  # `<<Version:32, Flags:32, Instructions:32, Lines:32, Files:32>>`,
  # then `Lines` integer-tagged compact terms interleaved with the
  # atom-tagged ones that switch file, then the file names as
  # `<<Length:16, Name>>`. Mix compiles with names relative to the
  # project, so this is usually a no-op; a file compiled outside its
  # working directory is named in full.
  defp line_files(
         <<header::binary-size(12), lines::32, files::32, items::binary>> = data,
         root
       ) do
    table_at = byte_size(items) - byte_size(skip_line_items(items, lines))
    <<entries::binary-size(table_at), table::binary>> = items

    names = file_names(table, files, root, <<>>)
    <<header::binary, lines::32, files::32, entries::binary, names::binary>>
  rescue
    # A table this reader does not follow is hashed as written: at worst
    # a miss, never two different tables made equal.
    _malformed in [MatchError, FunctionClauseError, CaseClauseError, ArgumentError] -> data
  end

  defp line_files(data, _root), do: data

  # Exactly `count` names and nothing after them, or the match fails.
  defp file_names(<<>>, 0, _root, acc), do: acc

  defp file_names(<<len::16, name::binary-size(len), rest::binary>>, count, root, acc)
       when count > 0 do
    normalized = walk_paths(name, root, [])

    file_names(
      rest,
      count - 1,
      root,
      <<acc::binary, byte_size(normalized)::16, normalized::binary>>
    )
  end

  defp skip_line_items(rest, 0), do: rest

  defp skip_line_items(items, n) do
    case compact_term(items) do
      {:atom, rest} -> skip_line_items(rest, n)
      {:integer, rest} -> skip_line_items(rest, n - 1)
    end
  end

  # One compact-term item of a line table (beam_asm's encoding): the tag
  # in the low three bits, `i` (1) for a line or `a` (2) for a file
  # switch; the value in the high bits (small), in three bits and the
  # next byte (medium), or in 2 to 8 following bytes (large). Nothing
  # else appears in a line table.
  defp compact_term(<<byte, rest::binary>>) do
    kind =
      case Bitwise.band(byte, 0x07) do
        1 -> :integer
        2 -> :atom
      end

    rest =
      cond do
        Bitwise.band(byte, 0x08) == 0 ->
          rest

        Bitwise.band(byte, 0x10) == 0 ->
          <<_next, rest::binary>> = rest
          rest

        Bitwise.bsr(byte, 5) < 7 ->
          size = Bitwise.bsr(byte, 5) + 2
          <<_value::binary-size(size), rest::binary>> = rest
          rest
      end

    {kind, rest}
  end

  # -- Paths --

  defp paths(term, root), do: walk_paths(term, root, String.to_charlist(root))

  defp walk_paths(bin, root, _chars) when is_binary(bin) do
    if :binary.match(bin, root) == :nomatch,
      do: bin,
      else: :binary.replace(bin, root, @marker, [:global])
  end

  defp walk_paths([_ | _] = list, root, chars) do
    case strip_prefix(list, chars) do
      {:ok, rest} -> String.to_charlist(@marker) ++ walk_paths(rest, root, chars)
      :error -> walk_list(list, root, chars)
    end
  end

  defp walk_paths(tuple, root, chars) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&walk_paths(&1, root, chars)) |> List.to_tuple()
  end

  defp walk_paths(map, root, chars) when is_map(map) do
    # Through `:maps`, not `Enum`: a struct in a literal is a map with
    # no `Enumerable` implementation.
    :maps.fold(
      fn k, v, acc -> Map.put(acc, walk_paths(k, root, chars), walk_paths(v, root, chars)) end,
      %{},
      map
    )
  end

  defp walk_paths(other, _root, _chars), do: other

  # Elements of a list, which may be improper.
  defp walk_list([head | tail], root, chars),
    do: [walk_paths(head, root, chars) | walk_list(tail, root, chars)]

  defp walk_list([], _root, _chars), do: []
  defp walk_list(tail, root, chars), do: walk_paths(tail, root, chars)

  defp strip_prefix(rest, []), do: {:ok, rest}
  defp strip_prefix([c | rest], [c | prefix]), do: strip_prefix(rest, prefix)
  defp strip_prefix(_list, _prefix), do: :error

  # -- Helpers --

  defp hash(parts) do
    parts
    |> Enum.reduce(:crypto.hash_init(:sha256), fn part, hash ->
      :crypto.hash_update(hash, <<byte_size(part)::64>> <> part)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp memo(key, compute) do
    key = {__MODULE__, key}

    case :persistent_term.get(key, :none) do
      :none ->
        value = compute.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end
end
