defmodule Roux.Lang do
  @moduledoc """
  Convention layer defining what it means to be a "language" in the Roux ecosystem.

  Languages implement this behaviour to specify file extensions, query registrations,
  and entry points. `Roux.Lang` is not required to use Roux — it's a convenience for
  the common case of building compilers.

  ## Usage

      defmodule MyLang do
        @behaviour Roux.Lang
        use Roux.Query

        @impl true
        def file_extensions, do: [".ml"]

        @impl true
        def compile_query, do: :compile

        @impl true
        def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

        definput :source_text, durability: :low

        defquery :parse, key: file_path do
          source = input(db, :source_text, file_path)
          MyLang.Parser.parse(source)
        end

        defquery :compile, key: file_path do
          ast = query(db, :parse, file_path)
          MyLang.Codegen.compile(ast)
        end
      end

  ## Registration

  Languages are registered with a database via `register/2`:

      db = Roux.Database.new()
      Roux.Lang.register(db, MyLang)

  Registration calls `register_queries/1` on the language module, then records
  file extension mappings. Extension conflicts raise `ArgumentError`.

  ## Cross-language interfaces

  When multiple languages coexist, they may need to reference each other's exports.
  The optional `module_interface/2` callback enables this — `resolve_interface/2`
  dispatches to the correct language based on file extension.
  """

  alias Roux.Database
  alias Roux.Input
  alias Roux.Query

  @type source_path :: String.t()
  @type module_interface :: term()

  # -- Required callbacks --

  @doc "File extensions this language handles (e.g., `[\".myex\", \".myl\"]`)."
  @callback file_extensions() :: [String.t()]

  @doc "Register all queries for this language with the database."
  @callback register_queries(Database.t()) :: :ok

  @doc "The query name that compiles a single file. Called by the Mix compiler."
  @callback compile_query() :: atom()

  # -- Optional IDE support callbacks --

  @doc "Query that produces diagnostics for a file."
  @callback diagnostics_query() :: atom()

  @doc "Query that produces completions at a position."
  @callback completions_query() :: atom()

  @doc "Query that produces hover info at a position."
  @callback hover_query() :: atom()

  @doc "Query that produces go-to-definition results."
  @callback definition_query() :: atom()

  @doc "Query that produces document symbols for the outline."
  @callback document_symbols_query() :: atom()

  # -- Optional editor integration callbacks --

  @doc "Line comment prefixes for this language (e.g., `[\"# \"]`)."
  @callback line_comments() :: [String.t()]

  @doc "Display name for this language (e.g., `\"Lark\"`)."
  @callback language_name() :: String.t()

  # -- Optional cross-language callback --

  @doc "Return the public interface of a compiled module."
  @callback module_interface(Database.t(), source_path()) :: module_interface()

  @doc """
  Called after source discovery, before compilation begins.

  Receives the database and the list of source paths belonging to this language.
  Use this to populate inputs that depend on knowing all source files (e.g.,
  module registries that map module names to file paths).
  """
  @callback prepare(Database.t(), [source_path()]) :: :ok

  @optional_callbacks [
    diagnostics_query: 0,
    completions_query: 0,
    hover_query: 0,
    definition_query: 0,
    document_symbols_query: 0,
    module_interface: 2,
    prepare: 2,
    line_comments: 0,
    language_name: 0
  ]

  # -- Public API --

  @doc """
  Registers a language with the database.

  Calls `lang_module.register_queries(db)` to register all queries, then records
  file extension mappings in the input registry using `{:__roux_lang__, extension}`
  tuple keys.

  Raises `ArgumentError` if an extension is already claimed by a different language.
  Idempotent — registering the same language twice is a no-op.
  """
  @spec register(Database.t(), module()) :: :ok
  def register(%Database{} = db, lang_module) when is_atom(lang_module) do
    extensions = lang_module.file_extensions()

    if already_registered?(db, lang_module, extensions) do
      :ok
    else
      lang_module.register_queries(db)

      Enum.each(extensions, fn ext ->
        key = {:__roux_lang__, ext}

        case :ets.insert_new(db.input_registry, {key, lang_module}) do
          true ->
            :ok

          false ->
            [{^key, existing}] = :ets.lookup(db.input_registry, key)

            if existing == lang_module do
              :ok
            else
              raise ArgumentError,
                    "extension #{inspect(ext)} is already claimed by #{inspect(existing)}, " <>
                      "cannot register #{inspect(lang_module)}"
            end
        end
      end)

      :ok
    end
  end

  @doc """
  Registers a module's queries and inputs with the database.

  Reads the module's `__roux_queries__/0` metadata (generated by `use Roux.Query`)
  and registers each input definition via `Roux.Input.register/2` and each query
  definition via `Roux.Database.register_query/3`.

  Intended to be called from a language's `register_queries/1` callback.
  """
  @spec register_module(Database.t(), module()) :: :ok
  def register_module(%Database{} = db, module) when is_atom(module) do
    metadata = module.__roux_queries__()

    Enum.each(Map.get(metadata, :entities, []), fn entity_module ->
      Database.register_entity(db, entity_module)
    end)

    Enum.each(metadata.inputs, fn %Input.Definition{} = defn ->
      Input.register(db, defn)
    end)

    Enum.each(metadata.queries, fn %Query.Definition{} = defn ->
      Database.register_query(db, defn.name, %{module: defn.module, function: defn.function})
    end)

    :ok
  end

  @doc """
  Looks up the language module registered for a file extension.

  Returns `{:ok, module}` if found, `:error` otherwise.
  """
  @spec lang_for_extension(Database.t(), String.t()) :: {:ok, module()} | :error
  def lang_for_extension(%Database{} = db, extension) when is_binary(extension) do
    case :ets.lookup(db.input_registry, {:__roux_lang__, extension}) do
      [{_, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @doc """
  Resolves the public interface of a source file by dispatching to the
  appropriate language's `module_interface/2` callback.

  Raises `ArgumentError` if no language is registered for the file's extension.
  """
  @spec resolve_interface(Database.t(), source_path()) :: module_interface()
  def resolve_interface(%Database{} = db, source_path) when is_binary(source_path) do
    ext = Path.extname(source_path)

    case lang_for_extension(db, ext) do
      {:ok, lang} -> lang.module_interface(db, source_path)
      :error -> raise ArgumentError, "no language registered for extension #{inspect(ext)}"
    end
  end

  @doc """
  Returns all language modules registered with the database.
  """
  @spec registered_languages(Database.t()) :: [module()]
  def registered_languages(%Database{} = db) do
    db.input_registry
    |> :ets.match({{:__roux_lang__, :_}, :"$1"})
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Returns the line comment prefixes for a language module.

  Falls back to `["# "]` if the module does not implement `line_comments/0`.
  """
  @spec line_comments(module()) :: [String.t()]
  def line_comments(lang_module) when is_atom(lang_module) do
    if function_exported?(lang_module, :line_comments, 0) do
      lang_module.line_comments()
    else
      ["# "]
    end
  end

  @doc """
  Returns the display name for a language module.

  Falls back to the last segment of the module name
  (e.g., `Lark` → `"Lark"`, `MyApp.HoverLang` → `"HoverLang"`).
  """
  @spec language_name(module()) :: String.t()
  def language_name(lang_module) when is_atom(lang_module) do
    if function_exported?(lang_module, :language_name, 0) do
      lang_module.language_name()
    else
      lang_module |> Module.split() |> List.last()
    end
  end

  # -- Private --

  # Checks if all extensions are already mapped to this module.
  defp already_registered?(db, lang_module, extensions) do
    Enum.all?(extensions, fn ext ->
      case :ets.lookup(db.input_registry, {:__roux_lang__, ext}) do
        [{_, ^lang_module}] -> true
        _ -> false
      end
    end)
  end
end
