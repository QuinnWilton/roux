defmodule Roux.Lang.Compiler do
  @moduledoc """
  Mix compiler integration for Roux languages.

  Discovers source files, updates inputs, dispatches compile queries, and
  persists state across VM restarts via a manifest. The incrementality
  logic lives in Roux's validation pipeline — this module orchestrates
  the top-level compile flow, on a `Roux.Session`: the files are synced
  into the `:source_text` input by `Roux.Sources` (a file whose stamp
  held is not read; one rewritten with the same content changes
  nothing), and a run that changed nothing writes nothing.

  ## Configuration

  Add `:roux` to your project's compilers list and configure languages
  via the `:roux` key in `project/0`:

      def project do
        [
          compilers: [:roux] ++ Mix.compilers(),
          roux: [
            languages: [MyLang, AnotherLang],
            source_dirs: ["lib", "src"]  # optional, defaults to ["lib"]
          ],
          # ...
        ]
      end

  ## Languages compiled after it

  The compiler runs before `:elixir`, so the project's Elixir code can
  call what it compiles; but a language is Elixir code, and often the
  project's own, compiled by `:elixir`. It runs only languages compiled
  against this roux (`Roux.Query.format/0`): one not compiled yet (a
  cold build), or compiled against a roux of another definition format
  (an upgrade, after which Mix recompiles what uses roux), is compiled
  only once `:elixir` has run. When `:elixir` follows `:roux` in the
  project's compilers, the run waits for it
  (`Mix.Task.Compiler.after_compiler/2`), and compiles the sources then;
  a language still not ready then is an error. Otherwise a language not
  compiled yet compiles nothing, and one of another format is an error.
  """

  use Mix.Task.Compiler

  alias Roux.{Database, Lang, Query, Session, Sources}
  alias Roux.Query.FormatError

  @doc """
  Runs the Roux compiler.

  Reads configuration from the `:roux` key in `Mix.Project.config/0` and
  delegates to `compile/1`.
  """
  @impl true
  @spec run(list()) ::
          {:ok, [Mix.Task.Compiler.Diagnostic.t()]}
          | {:error, [Mix.Task.Compiler.Diagnostic.t()]}
          | {:noop, []}
  def run(_argv) do
    compile(Mix.Project.config()[:roux] || [])
  end

  @doc """
  Compiles with the given Roux configuration.

  Accepts a keyword list with `:languages` and `:source_dirs` keys.
  Returns `{:ok, diagnostics}`, `{:error, diagnostics}`, or `{:noop, []}`.
  """
  @spec compile(keyword()) ::
          {:ok, [Mix.Task.Compiler.Diagnostic.t()]}
          | {:error, [Mix.Task.Compiler.Diagnostic.t()]}
          | {:noop, []}
  def compile(roux_config), do: compile(roux_config, :first)

  defp compile(roux_config, attempt) do
    languages = Keyword.get(roux_config, :languages, [])
    source_dirs = Keyword.get(roux_config, :source_dirs, ["lib"])

    if languages == [] do
      {:noop, []}
    else
      case open(languages) do
        {:ok, session} ->
          try do
            compile_session(session, languages, source_dirs, roux_config)
          after
            Session.close(session)
          end

        {:not_ready, reason} ->
          not_ready(reason, roux_config, attempt)
      end
    end
  end

  # A session over the languages, once each is compiled against this
  # roux; otherwise why not: a language not compiled yet, or a module
  # of queries compiled against a roux of another definition format.
  # A language's own format is checked before anything of it runs.
  defp open(languages) do
    with :ok <- Enum.reduce_while(languages, :ok, &ready/2) do
      # Mix compilers run before app.start, so telemetry isn't started yet.
      {:ok, _} = Application.ensure_all_started(:telemetry)

      try do
        {:ok, Session.open(languages: languages, manifest: manifest_path())}
      rescue
        error in FormatError -> {:not_ready, {:stale, error}}
      end
    end
  end

  defp ready(lang, :ok) do
    cond do
      not Code.ensure_loaded?(lang) ->
        {:halt, {:not_ready, {:unavailable, lang}}}

      not function_exported?(lang, :__roux_queries__, 0) ->
        {:cont, :ok}

      true ->
        case Query.check_format(lang) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:not_ready, {:stale, error}}}
        end
    end
  end

  # The first attempt waits for `:elixir` when it follows; the attempt
  # after it has nothing left to wait for.
  defp not_ready(reason, roux_config, :first) do
    cond do
      elixir_follows?() ->
        Mix.Task.Compiler.after_compiler(:elixir, &after_elixir(&1, roux_config))
        {:noop, []}

      match?({:unavailable, _}, reason) ->
        {:noop, []}

      true ->
        failed(reason)
    end
  end

  defp not_ready(reason, _roux_config, :after_elixir), do: failed(reason)

  defp elixir_follows? do
    compilers = Mix.Project.config()[:compilers] || Mix.compilers()
    :elixir in Enum.drop_while(compilers, &(&1 != :roux))
  end

  # What `:elixir` returned, and this compiler's run after it: nothing
  # runs after an `:elixir` that failed.
  defp after_elixir({:error, _} = elixir, _roux_config), do: elixir

  defp after_elixir({status, diagnostics}, roux_config) do
    {roux_status, roux_diagnostics} = compile(roux_config, :after_elixir)
    {merge_status(status, roux_status), diagnostics ++ roux_diagnostics}
  end

  defp merge_status(_status, :error), do: :error
  defp merge_status(:ok, _roux_status), do: :ok
  defp merge_status(_status, roux_status), do: roux_status

  defp failed({:unavailable, lang}) do
    fail(
      diagnostic(
        Mix.Project.project_file() || "mix.exs",
        "language #{inspect(lang)} is not available: it is neither a dependency's " <>
          "nor compiled from the project's Elixir code (the :languages of the :roux config)",
        :error
      )
    )
  end

  # Reached when the Elixir compiler did not recompile the module: it
  # saw no change to it, or it is a dependency's.
  defp failed({:stale, %FormatError{module: module} = error}) do
    message =
      Exception.message(error) <>
        " (mix compile --force recompiles the project's modules, " <>
        "mix deps.compile --force a dependency's)"

    fail(diagnostic(source_of(module), message, :error))
  end

  defp fail(diagnostic) do
    print_diagnostic(diagnostic)
    {:error, [diagnostic]}
  end

  # Where a diagnostic about a module points: its source, when the
  # module was compiled from a file that is still there.
  defp source_of(module) do
    with source when is_list(source) <- module.module_info(:compile)[:source],
         true <- File.regular?(source) do
      List.to_string(source)
    else
      _ -> Mix.Project.project_file() || "mix.exs"
    end
  end

  defp compile_session(%Session{db: db} = session, languages, source_dirs, roux_config) do
    source_paths = find_sources(languages, source_dirs)

    %{meta: meta, changed: changed, removed: removed} =
      Sources.sync(db, :source_text, Map.new(source_paths, &{&1, &1}), session.sources,
        value: fn %{content: content} -> content end
      )

    prepare_languages(db, languages, source_paths)

    if session.restored? and changed == [] and removed == [] do
      if Keyword.get(roux_config, :verbose, false) do
        Mix.shell().info("All roux files are up to date")
      end

      # Nothing to compile; stamps a touch moved are kept, so the next
      # run does not read those files again.
      _ = Session.commit(session, meta)
      {:noop, []}
    else
      print_compiling(changed)
      diagnostics = compile_all(db, languages, source_paths)
      Enum.each(diagnostics, &print_diagnostic/1)

      if Enum.any?(diagnostics, &(&1.severity == :error)) do
        {:error, diagnostics}
      else
        _ = Session.commit(session, meta)
        {:ok, diagnostics}
      end
    end
  end

  @doc """
  Returns the list of manifest file paths managed by this compiler.
  """
  @impl true
  @spec manifests() :: [String.t()]
  def manifests, do: [manifest_path()]

  @doc """
  Removes the manifest file.
  """
  @impl true
  @spec clean() :: :ok
  def clean do
    File.rm(manifest_path())
    :ok
  end

  # -- Private: configuration --

  defp manifest_path do
    Path.join(Mix.Project.manifest_path(), "compile.roux")
  end

  # -- Private: source discovery --

  # Finds all source files matching registered language extensions.
  defp find_sources(languages, source_dirs) do
    extensions =
      languages
      |> Enum.flat_map(& &1.file_extensions())
      |> MapSet.new()

    source_dirs
    |> Enum.flat_map(&Lang.walk_directory/1)
    |> Enum.filter(fn path -> MapSet.member?(extensions, Path.extname(path)) end)
    |> Enum.sort()
  end

  # Calls prepare/2 on languages that implement it, passing their source paths.
  defp prepare_languages(db, languages, source_paths) do
    ext_to_lang = build_ext_to_lang(languages)

    paths_by_lang =
      Enum.group_by(source_paths, fn path ->
        Map.get(ext_to_lang, Path.extname(path))
      end)

    Enum.each(languages, fn lang ->
      if function_exported?(lang, :prepare, 2) do
        lang_paths = Map.get(paths_by_lang, lang, [])
        lang.prepare(db, lang_paths)
      end
    end)
  end

  # -- Private: compilation --

  # Builds an extension→language map, then compiles each source file.
  defp compile_all(db, languages, source_paths) do
    output_dir = Mix.Project.compile_path()
    File.mkdir_p!(output_dir)

    ext_to_lang = build_ext_to_lang(languages)

    # Phase 1: Run compile queries and collect results + diagnostics.
    {modules, diagnostics} =
      Enum.reduce(source_paths, {[], []}, fn path, {mods, diags} ->
        ext = Path.extname(path)

        case Map.fetch(ext_to_lang, ext) do
          {:ok, lang} ->
            {mod, file_diags} = compile_file(db, lang, path)
            {[mod | mods], diags ++ file_diags}

          :error ->
            {mods, diags}
        end
      end)

    # Phase 2: Emit all modules at once so cross-module references resolve.
    emit_diags = emit_modules(modules, output_dir)

    diagnostics ++ emit_diags
  end

  # Compiles a single file, catching errors and converting to diagnostics.
  # Returns {quoted_ast | nil, diagnostics}.
  defp compile_file(db, lang, path) do
    compile_query = lang.compile_query()

    try do
      result = dispatch_query(db, compile_query, path)
      diags = collect_diagnostics(db, lang, path)
      quoted = if match?({:ok, _}, result), do: {path, elem(result, 1)}
      {quoted, diags}
    rescue
      e in [CompileError, SyntaxError, TokenMissingError, ArgumentError, RuntimeError] ->
        {nil, [diagnostic(path, Exception.message(e), :error)]}
    catch
      {:roux_query_error, reason} ->
        message = if is_binary(reason), do: reason, else: inspect(reason)
        {nil, [diagnostic(path, message, :error)]}
    end
  end

  # Compiles all quoted module ASTs together and writes .beam files.
  # Compiling as a single block ensures cross-module references resolve.
  # Returns a list of diagnostics for compilation failures.
  defp emit_modules(modules, output_dir) do
    quoted_asts =
      modules
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {_path, quoted} -> quoted end)

    case quoted_asts do
      [] ->
        []

      asts ->
        block = {:__block__, [], asts}

        try do
          compiled = Code.compile_quoted(block)

          Enum.each(compiled, fn {module, binary} ->
            beam_path = Path.join(output_dir, "#{module}.beam")
            File.write!(beam_path, binary)
          end)

          []
        rescue
          e in [CompileError, SyntaxError, TokenMissingError] ->
            [diagnostic(e.file || "unknown", Exception.message(e), :error)]
        end
    end
  end

  defp dispatch_query(db, query_name, key) do
    Database.dispatch_query(db, query_name, key)
  end

  # Collects diagnostics from a language's diagnostics_query if defined.
  # Converts raw language diagnostic maps to Mix.Task.Compiler.Diagnostic structs.
  defp collect_diagnostics(db, lang, path) do
    if function_exported?(lang, :diagnostics_query, 0) do
      query_name = lang.diagnostics_query()

      try do
        case dispatch_query(db, query_name, path) do
          diagnostics when is_list(diagnostics) ->
            Enum.map(diagnostics, &to_mix_diagnostic(&1, path))

          _ ->
            []
        end
      rescue
        e in [ArgumentError] ->
          [diagnostic(path, "diagnostics query failed: #{Exception.message(e)}", :warning)]
      catch
        {:roux_query_error, _reason} ->
          []
      end
    else
      []
    end
  end

  # Converts a language diagnostic map to a Mix.Task.Compiler.Diagnostic.
  # The optional `:rendered` key is stored in `details` for rich terminal output.
  defp to_mix_diagnostic(%{message: message, severity: severity} = diag, file) do
    position =
      case diag do
        %{line: line, column: col} when is_integer(line) and is_integer(col) -> {line, col}
        %{line: line} when is_integer(line) -> line
        _ -> 1
      end

    mix_diag = diagnostic(file, message, severity, position)

    case diag do
      %{rendered: rendered} when is_binary(rendered) -> %{mix_diag | details: rendered}
      _ -> mix_diag
    end
  end

  # Prints "Compiling N files (.ext)" grouped by extension, matching the
  # format used by Elixir's built-in mix compiler.
  defp print_compiling(stale_paths) do
    stale_paths
    |> Enum.group_by(&Path.extname/1)
    |> Enum.sort()
    |> Enum.each(fn {ext, paths} ->
      count = length(paths)
      suffix = if count == 1, do: "file", else: "files"
      Mix.shell().info("Compiling #{count} #{suffix} (#{ext})")
    end)
  end

  # Prints a diagnostic to stderr. Uses the pre-rendered `details` when
  # available (e.g., pentiment-formatted output), falling back to a plain
  # location: severity: message format.
  defp print_diagnostic(%Mix.Task.Compiler.Diagnostic{details: rendered})
       when is_binary(rendered) do
    IO.puts(:stderr, rendered)
  end

  defp print_diagnostic(%Mix.Task.Compiler.Diagnostic{} = diag) do
    file = Path.relative_to_cwd(diag.file)

    location =
      case diag.position do
        {line, col} -> "#{file}:#{line}:#{col}"
        line when is_integer(line) -> "#{file}:#{line}"
        _ -> file
      end

    prefix =
      case diag.severity do
        :error -> "error"
        :warning -> "warning"
        :info -> "info"
        :hint -> "hint"
      end

    IO.puts(:stderr, "#{location}: #{prefix}: #{diag.message}")
  end

  # Builds an extension→language map from a list of language modules.
  defp build_ext_to_lang(languages) do
    Map.new(
      for lang <- languages,
          ext <- lang.file_extensions() do
        {ext, lang}
      end
    )
  end

  # Builds a Mix compiler diagnostic with an absolute file path.
  defp diagnostic(file, message, severity, position \\ 1) do
    %Mix.Task.Compiler.Diagnostic{
      file: Path.expand(file),
      message: message,
      severity: severity,
      compiler_name: "roux",
      position: position
    }
  end
end
