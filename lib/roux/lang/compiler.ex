defmodule Roux.Lang.Compiler do
  @moduledoc """
  Mix compiler integration for Roux languages.

  Discovers source files, updates inputs, dispatches compile queries, and
  persists state across VM restarts via a manifest. The incrementality
  logic lives in Roux's validation pipeline — this module orchestrates
  the top-level compile flow.

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
  """

  use Mix.Task.Compiler

  alias Roux.{Database, GC, Input, Lang}
  alias Roux.Lang.Manifest

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
  def compile(roux_config) do
    languages = Keyword.get(roux_config, :languages, [])
    source_dirs = Keyword.get(roux_config, :source_dirs, ["lib"])

    # Skip if no languages configured or if language modules aren't compiled yet
    # (cold bootstrap: roux compiler runs before elixir compiler has built them).
    if languages == [] or not Enum.all?(languages, &Code.ensure_loaded?/1) do
      {:noop, []}
    else
      # Mix compilers run before app.start, so telemetry isn't started yet.
      {:ok, _} = Application.ensure_all_started(:telemetry)

      db = Database.new()

      try do
        Enum.each(languages, &Lang.register(db, &1))
        source_paths = find_sources(languages, source_dirs)

        manifest_data = Manifest.load(manifest_path())
        change_status = handle_manifest(db, manifest_data, source_paths)

        prepare_languages(db, languages, source_paths)

        case change_status do
          :noop ->
            if Keyword.get(roux_config, :verbose, false) do
              Mix.shell().info("All roux files are up to date")
            end

            {:noop, []}

          {:changed, stale_paths} ->
            print_compiling(stale_paths)
            diagnostics = compile_all(db, languages, source_paths)
            Enum.each(diagnostics, &print_diagnostic/1)

            if Enum.any?(diagnostics, &(&1.severity == :error)) do
              {:error, diagnostics}
            else
              source_meta = Manifest.source_metadata(source_paths)
              Manifest.write(db, source_meta, manifest_path())

              {:ok, diagnostics}
            end
        end
      after
        Database.shutdown(db)
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

  # -- Private: manifest handling --

  defp handle_manifest(db, {:ok, manifest_data}, current_paths) do
    Manifest.restore(db, manifest_data)
    saved_sources = manifest_data.sources
    current_set = MapSet.new(current_paths)

    # Deleted: in manifest but no longer on disk.
    deleted =
      saved_sources
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(current_set, &1))

    Enum.each(deleted, &GC.mark_input_removed(db, :source_text, &1))

    # Stale: mtime changed or new file — must re-read from disk.
    # Fresh files are skipped entirely: their :source_text input entries
    # were restored from the manifest by Manifest.restore/2.
    stale =
      Enum.filter(current_paths, fn path ->
        case Map.fetch(saved_sources, path) do
          {:ok, %{mtime: saved_mtime}} ->
            %File.Stat{mtime: mtime} = File.stat!(path)
            mtime != saved_mtime

          :error ->
            true
        end
      end)

    populate_inputs(db, stale)

    if stale == [] and deleted == [] do
      :noop
    else
      {:changed, stale}
    end
  end

  defp handle_manifest(db, :error, source_paths) do
    # Cold build — set all inputs.
    populate_inputs(db, source_paths)
    {:changed, source_paths}
  end

  # Reads file contents and sets the :source_text input for each path.
  defp populate_inputs(db, paths) do
    Enum.each(paths, fn path ->
      content = File.read!(path)
      Input.set(db, :source_text, path, content)
    end)
  end

  # Calls prepare/2 on languages that implement it, passing their source paths.
  defp prepare_languages(db, languages, source_paths) do
    ext_to_lang =
      Map.new(
        for lang <- languages,
            ext <- lang.file_extensions() do
          {ext, lang}
        end
      )

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

    ext_to_lang =
      Map.new(
        for lang <- languages,
            ext <- lang.file_extensions() do
          {ext, lang}
        end
      )

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
