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

  ## Code versions

  A memoized value is a function of what its query read and of the
  code that computed it. Roux tracks the reads; the code it knows about
  through a query's *code version*, stored with each entry: an entry
  computed by another version of its query is stale (`Roux.Validation`),
  and re-executes — keeping its `changed_at` when it comes back to the
  same value, so an edit that changes no result recomputes nothing
  downstream.

      use Roux.Query, code: [exclude: &MyApp.Schema.schema_module?/1]

      defquery :facts, key: module, code: {MyApp.Extractors, :all, []} do
        ...
      end

      defquery :render, key: finding, version: 2 do
        ...
      end

  `use Roux.Query, code: opts` versions every query of the module by
  the code its module reaches (`Roux.Code.digest/2`, given `opts`; `true`
  for none): an edit to any module that code calls moves the version of
  every query here, and an edit anywhere else moves none. Split queries
  into modules by what they run to keep each closure tight. A query's
  own `code:` adds roots its body reaches by dynamic dispatch — a list
  of modules, or `{m, f, a}` returning one at registration — and turns
  code versions on for that query alone when the module's are off.
  `version:` is a term mixed into the version by hand, for a change the
  code cannot show (a rule file read at runtime, a format).

  Versions are computed when the module is registered
  (`Roux.Lang.register_module/2`), once per VM for each set of roots. A
  module compiled in memory has no object code to read: its queries get
  a version that no other VM shares, so their entries never outlive the
  VM.

  ## Persistence

  A manifest (`Roux.Lang.Manifest`) keeps every entry by default, its
  value inline. A query can say otherwise:

      defquery :findings, key: analysis, store: :blob do ... end

      defquery :facts, key: module, transient: &match?({:error, :lost}, &1) do
        ...
      end

    * `store: :inline` (the default) — the value is in the manifest;
    * `store: :blob` — the value is kept in the manifest's `Roux.Blob`
      store by digest, read back lazily, and its early cutoff compares
      digests: for large values the manifest need not carry;
    * `store: :none` — never kept: cheap to recompute, or meaningless in
      another VM;
    * `transient: predicate` — a value the predicate accepts is not
      kept, and neither is any entry that read it, directly or not: a
      reader restored without it would pass its durability check and
      serve what the transient value led to, never asking again. For a
      value that stands for a failure worth retrying next run.

  ## Wrapping bodies

  `use Roux.Query, around: {m, f}` runs every query body of the module
  inside `m.f(context, body)`, where `context` is
  `%{db: db, query: name, key: key}` and `body` a zero-arity function
  returning the body's value; `f` returns what the query returns. It
  runs inside the query's execution, so what it reads becomes the
  query's dependencies: a hook that records what the body read some
  other way and turns it into edges.
  """

  alias Roux.Query.Definition

  @type query_name :: atom()
  @type definition :: Definition.t()

  @typedoc "What `use Roux.Query, code: ...` holds: nil, or the options of `Roux.Code.digest/2`."
  @type code_options :: [Roux.Code.option()] | nil

  @doc false
  defmacro __using__(opts) do
    code =
      case Keyword.get(opts, :code) do
        nil -> nil
        false -> nil
        true -> []
        list when is_list(list) -> list
      end

    around = Keyword.get(opts, :around)

    quote do
      import Roux.Query,
        only: [defquery: 2, defquery: 3, definput: 1, definput: 2, defentity: 1]

      Module.register_attribute(__MODULE__, :roux_queries, accumulate: true)
      Module.register_attribute(__MODULE__, :roux_inputs, accumulate: true)
      Module.register_attribute(__MODULE__, :roux_entities, accumulate: true)
      @roux_code unquote(code)
      @roux_around unquote(around)

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
    * `:code` — (optional) roots of the query's code beyond its module:
      a list of modules or `{module, function, args}` (see "Code versions")
    * `:version` — (optional) a term mixed into the query's code version
    * `:store` — (optional) `:inline`, `:blob` or `:none` (see "Persistence")
    * `:transient` — (optional) a predicate over the value (see "Persistence")
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
    {code, opts} = Keyword.pop(opts, :code)
    {version, opts} = Keyword.pop(opts, :version)
    {store, opts} = Keyword.pop(opts, :store, :inline)
    {transient, opts} = Keyword.pop(opts, :transient)

    unless store in [:inline, :blob, :none] do
      raise ArgumentError,
            "defquery #{inspect(name)}: :store must be :inline, :blob or :none, " <>
              "got: #{Macro.to_string(store)}"
    end

    # The predicate is code, not data: it becomes a function of the
    # module's, which the definition names.
    transient_fun = if transient, do: :"__roux_transient_#{name}__"

    transient_ast =
      if transient do
        quote do
          @doc false
          def unquote(transient_fun)(value), do: unquote(transient).(value)
        end
      end

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
        opts: unquote(opts),
        code: unquote(code),
        version: unquote(version),
        store: unquote(store),
        transient: unquote(if transient_fun, do: quote(do: {__MODULE__, unquote(transient_fun)}))
      }

      unquote(transient_ast)

      unquote(spec_ast)

      def unquote(name)(var!(db), unquote(key_pattern)) do
        Roux.Runtime.execute(
          var!(db),
          unquote(name),
          unquote(key_pattern),
          fn var!(db), unquote(key_pattern) ->
            Roux.Query.__run__(
              @roux_around,
              var!(db),
              unquote(name),
              unquote(key_pattern),
              fn ->
                try do
                  unquote(body)
                catch
                  :throw, {:roux_query_error, reason} -> {:error, reason}
                end
              end
            )
          end
        )
      end
    end
  end

  @doc false
  # Runs a query body, inside the module's `around:` hook when it has one.
  @spec __run__({module(), atom()} | nil, Roux.Database.t(), atom(), term(), (-> result)) ::
          result
        when result: var
  def __run__(nil, _db, _name, _key, body), do: body.()

  def __run__({module, function}, db, name, key, body),
    do: apply(module, function, [%{db: db, query: name, key: key}, body])

  @doc """
  The code version of `definition` (see "Code versions"), given the
  code options of its module (`use Roux.Query, code: ...`): nil for a
  query with neither code versions nor a `version:`. With a `Roux.Blob`
  store, the code's digest is kept there across VMs (`Roux.Code`).
  """
  @spec code_version(Definition.t(), code_options(), Roux.Blob.t() | nil) :: binary() | nil
  def code_version(definition, module_code, store \\ nil)

  def code_version(%Definition{code: nil, version: nil}, nil, _store), do: nil

  def code_version(%Definition{} = definition, module_code, store) do
    code =
      if module_code != nil or definition.code != nil do
        roots = [definition.module | extra_roots(definition)]

        case Roux.Code.digest(roots, (module_code || []) ++ [store: store]) do
          {:ok, digest} -> digest
          {:error, reason} -> {:unversioned, reason, vm_token()}
        end
      end

    :crypto.hash(:sha256, :erlang.term_to_binary({code, definition.version}, [:deterministic]))
  end

  defp extra_roots(%Definition{code: nil}), do: []
  defp extra_roots(%Definition{code: roots}) when is_list(roots), do: roots

  defp extra_roots(%Definition{code: {m, f, a}} = definition) do
    case apply(m, f, a) do
      roots when is_list(roots) ->
        roots

      other ->
        raise ArgumentError,
              "the code roots of query #{inspect(definition.name)} " <>
                "(#{inspect(m)}.#{f}/#{length(a)}) must be a list of modules, got: " <>
                inspect(other)
    end
  end

  # What a version no other VM shares is made of: code with no object
  # code to read can be named only within the VM that loaded it.
  defp vm_token do
    key = {__MODULE__, :vm_token}

    case :persistent_term.get(key, nil) do
      nil ->
        token = :crypto.strong_rand_bytes(16)
        :persistent_term.put(key, token)
        token

      token ->
        token
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

    code = Module.get_attribute(env.module, :roux_code)

    roux_queries_fn =
      quote do
        def __roux_queries__ do
          %{
            queries: unquote(Macro.escape(queries)),
            inputs: unquote(Macro.escape(inputs)),
            entities: unquote(Macro.escape(entities)),
            code: unquote(Macro.escape(code))
          }
        end
      end

    {:__block__, [], query_definition_clauses ++ [roux_queries_fn]}
  end
end
