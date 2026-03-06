defmodule Roux.Query do
  @moduledoc """
  Derived query definition and the `defquery` macro.

  A derived query is a pure function from a key to a value that may call other
  queries. The framework memoizes results and tracks dependencies automatically.

  ## Usage

      defmodule MyLang.Queries do
        use Roux.Query

        definput :source_text, durability: :low
        defentity MyLang.Definition

        defquery :parse, key: file_path, returns: {:ok, [atom()]} | {:error, term()} do
          source = input(db, :source_text, file_path)
          MyParser.parse(source)
        end
      end

  `defquery` generates a public function wrapping the body in
  `Roux.Runtime.execute/4` for memoization and dependency tracking.
  `definput` records an input definition for bulk registration.
  `defentity` declares an entity type for automatic registration.
  """

  alias Roux.Query.Definition

  @type query_name :: atom()
  @type definition :: Definition.t()

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Roux.Query,
        only: [defquery: 2, defquery: 3, definput: 1, definput: 2, defentity: 1]

      Module.register_attribute(__MODULE__, :roux_queries, accumulate: true)
      Module.register_attribute(__MODULE__, :roux_inputs, accumulate: true)
      Module.register_attribute(__MODULE__, :roux_entities, accumulate: true)

      @before_compile Roux.Query
    end
  end

  @doc """
  Defines a derived query.

  Generates a public function `name(db, key)` that wraps the body in
  `Roux.Runtime.execute/4` and accumulates a `Roux.Query.Definition` for
  registration.

  ## Options

    * `:key` — (required) the key parameter pattern
    * `:returns` — (optional) return type; generates a `@spec` for the query function
    * `:do` — the query body block

  ## Example

      defquery :parse, key: file_path, returns: {:ok, [AST.t()]} | {:error, String.t()} do
        source = input(db, :source_text, file_path)
        MyParser.parse(source)
      end

  """
  # do...end block after keyword arguments is a separate argument in Elixir.
  defmacro defquery(name, opts, do_block) do
    build_defquery(name, Keyword.merge(opts, do_block))
  end

  defmacro defquery(name, opts) do
    build_defquery(name, opts)
  end

  defp build_defquery(name, opts) do
    {body, opts} = Keyword.pop!(opts, :do)
    {key_pattern, opts} = Keyword.pop!(opts, :key)
    {returns, opts} = Keyword.pop(opts, :returns)

    spec_ast =
      if returns do
        quote do
          @spec unquote(name)(Roux.Database.t(), term()) :: unquote(returns)
        end
      end

    quote do
      @roux_queries %Roux.Query.Definition{
        name: unquote(name),
        module: __MODULE__,
        function: unquote(name),
        opts: unquote(opts)
      }

      unquote(spec_ast)

      def unquote(name)(var!(db), unquote(key_pattern)) do
        Roux.Runtime.execute(
          var!(db),
          unquote(name),
          unquote(key_pattern),
          fn var!(db), unquote(key_pattern) ->
            try do
              unquote(body)
            catch
              :throw, {:roux_query_error, reason} -> {:error, reason}
            end
          end
        )
      end
    end
  end

  @doc """
  Declares an input with optional durability.

  Accumulates a `Roux.Input.Definition` for bulk registration. Does not
  create the input in the database — that happens at module registration time.

  ## Options

    * `:durability` — `:high`, `:medium`, or `:low` (default: `:medium`)

  """
  defmacro definput(name, opts \\ []) do
    durability = Keyword.get(opts, :durability, :medium)

    quote do
      @roux_inputs %Roux.Input.Definition{
        name: unquote(name),
        durability: unquote(durability)
      }
    end
  end

  @doc """
  Declares an entity type for automatic registration.

  Accumulates the entity module so that `Roux.Lang.register_module/2`
  registers it with the database alongside queries and inputs.

  ## Example

      defentity MyLang.Function

  """
  defmacro defentity(module) do
    quote do
      @roux_entities unquote(module)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    queries = env.module |> Module.get_attribute(:roux_queries) |> Enum.reverse()
    inputs = env.module |> Module.get_attribute(:roux_inputs) |> Enum.reverse()
    entities = env.module |> Module.get_attribute(:roux_entities) |> Enum.reverse()

    query_definition_clauses =
      for %Definition{name: name} = defn <- queries do
        escaped = Macro.escape(defn)

        quote do
          def __query_definition__(unquote(name)), do: unquote(escaped)
        end
      end

    roux_queries_fn =
      quote do
        def __roux_queries__ do
          %{
            queries: unquote(Macro.escape(queries)),
            inputs: unquote(Macro.escape(inputs)),
            entities: unquote(Macro.escape(entities))
          }
        end
      end

    {:__block__, [], query_definition_clauses ++ [roux_queries_fn]}
  end
end
