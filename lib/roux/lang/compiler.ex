defmodule Roux.Lang.Compiler do
  @moduledoc """
  Mix compiler integration for Roux languages.

  Discovers source files, updates inputs, dispatches compile queries, and
  persists state across VM restarts via a manifest. The incrementality
  logic lives in Roux's validation pipeline — this module orchestrates
  the top-level compile flow.

  ## Configuration

      # In config.exs or runtime.exs:
      config :roux,
        languages: [MyLang, AnotherLang]

      # Optional — defaults to ["lib"]:
      config :roux,
        source_dirs: ["lib", "src"]

  ## Usage

  Add `:roux` to your project's compilers list:

      def project do
        [
          compilers: [:roux] ++ Mix.compilers(),
          # ...
        ]
      end
  """

  use Mix.Task.Compiler

  alias Roux.{Database, GC, Input, Lang}
  alias Roux.Lang.Manifest

  @doc """
  Runs the Roux compiler.

  Returns `{:ok, diagnostics}`, `{:error, diagnostics}`, or `{:noop, []}`.
  """
  @impl true
  @spec run(list()) ::
          {:ok, [Mix.Task.Compiler.Diagnostic.t()]}
          | {:error, [Mix.Task.Compiler.Diagnostic.t()]}
          | {:noop, []}
  def run(_argv) do
    languages = configured_languages()

    if languages == [] do
      {:noop, []}
    else
      db = Database.new()

      try do
        Enum.each(languages, &Lang.register(db, &1))
        source_paths = find_sources(languages)

        manifest_data = Manifest.load(manifest_path())
        change_status = handle_manifest(db, manifest_data, source_paths)

        case change_status do
          :noop ->
            {:noop, []}

          :changed ->
            diagnostics = compile_all(db, languages, source_paths)

            source_meta = Manifest.source_metadata(source_paths)
            Manifest.write(db, source_meta, manifest_path())

            if Enum.any?(diagnostics, &(&1.severity == :error)) do
              {:error, diagnostics}
            else
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

  defp configured_languages do
    Application.get_env(:roux, :languages, [])
  end

  defp source_dirs do
    Application.get_env(:roux, :source_dirs, ["lib"])
  end

  defp manifest_path do
    Path.join(Mix.Project.manifest_path(), "compile.roux")
  end

  # -- Private: source discovery --

  # Finds all source files matching registered language extensions.
  defp find_sources(languages) do
    extensions =
      languages
      |> Enum.flat_map(& &1.file_extensions())
      |> MapSet.new()

    source_dirs()
    |> Enum.flat_map(&walk_directory/1)
    |> Enum.filter(fn path -> MapSet.member?(extensions, Path.extname(path)) end)
    |> Enum.sort()
  end

  # Recursively walks a directory, returning all file paths.
  defp walk_directory(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          if File.dir?(full) do
            walk_directory(full)
          else
            [full]
          end
        end)

      {:error, _} ->
        []
    end
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
      :changed
    end
  end

  defp handle_manifest(db, :error, source_paths) do
    # Cold build — set all inputs.
    populate_inputs(db, source_paths)
    :changed
  end

  # Reads file contents and sets the :source_text input for each path.
  defp populate_inputs(db, paths) do
    Enum.each(paths, fn path ->
      content = File.read!(path)
      Input.set(db, :source_text, path, content)
    end)
  end

  # -- Private: compilation --

  # Builds an extension→language map, then compiles each source file.
  defp compile_all(db, languages, source_paths) do
    ext_to_lang =
      Map.new(
        for lang <- languages,
            ext <- lang.file_extensions() do
          {ext, lang}
        end
      )

    source_paths
    |> Enum.flat_map(fn path ->
      ext = Path.extname(path)

      case Map.fetch(ext_to_lang, ext) do
        {:ok, lang} -> compile_file(db, lang, path)
        :error -> []
      end
    end)
  end

  # Compiles a single file, catching errors and converting to diagnostics.
  defp compile_file(db, lang, path) do
    compile_query = lang.compile_query()

    try do
      dispatch_query(db, compile_query, path)
      collect_diagnostics(db, lang, path)
    rescue
      error ->
        message = Exception.message(error)
        [diagnostic(path, message, :error)]
    end
  end

  defp dispatch_query(db, query_name, key) do
    Database.dispatch_query(db, query_name, key)
  end

  # Collects diagnostics from a language's diagnostics_query if defined.
  defp collect_diagnostics(db, lang, path) do
    if function_exported?(lang, :diagnostics_query, 0) do
      query_name = lang.diagnostics_query()

      try do
        case dispatch_query(db, query_name, path) do
          diagnostics when is_list(diagnostics) -> diagnostics
          _ -> []
        end
      rescue
        _ -> []
      end
    else
      []
    end
  end

  # Builds a Mix compiler diagnostic.
  defp diagnostic(file, message, severity) do
    %Mix.Task.Compiler.Diagnostic{
      file: file,
      message: message,
      severity: severity,
      compiler_name: "roux",
      position: 1
    }
  end
end
