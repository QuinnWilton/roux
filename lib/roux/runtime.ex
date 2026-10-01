defmodule Roux.Runtime do
  @moduledoc """
  The query execution engine.

  Handles memoization, dependency tracking, cycle detection, validation,
  early cutoff, dedup, and write buffering. This is the core integration
  point where queries, memos, validation, and entities come together.

  ## Execution flow

  `execute/4` is the main entry point, called by `defquery`-generated
  functions. It checks the memo table, validates stale entries, and
  re-executes when needed. Results are buffered during execution and
  flushed to ETS on completion.

  ## Concurrency

  `execute/4` is synchronous and concurrent-safe. The dedup table
  prevents duplicate computation when multiple processes request the
  same query. Callers own their concurrency (e.g. `Task.async_stream`).
  `query/3` executes inline. `parallel/3` fans out, recording the fan-out
  as one dependency.

  See D3, D13, D14 for design rationale.
  """

  alias Roux.{
    Blob,
    Cancellation,
    Cycle,
    Database,
    Dependencies,
    Entity,
    GC,
    Memo,
    Revision,
    Telemetry,
    Validation
  }

  alias Roux.Memo.{Entry, Value}
  alias Roux.Runtime.Context
  alias Roux.Runtime.Scope

  @context_key {__MODULE__, :context}
  @boundary_key {__MODULE__, :boundary}

  # Served values, per process: `{@values_key, memo_table, query_key} =>
  # {changed_at, generation, value}`. ETS copies a term out on every read, and a
  # memoized structure (fact rows, syntax trees) is deep-copied in full;
  # a hot query graph reads the same large values thousands of times per
  # revision, so the first read caches the value on this process's heap
  # and later reads hand back the same term. `changed_at` is the guard:
  # a key executes at most once per revision and takes a new `changed_at`
  # whenever its value changes, so an equal `changed_at` is an equal
  # value. Reverse tracking also guards the exact memo incarnation: a manual
  # replacement can change a value without advancing changed_at. The table id
  # keeps caches of different databases apart.
  @values_key {__MODULE__, :value}

  # -- Public API --

  @doc """
  Executes a query with memoization and dependency tracking.

  Called by `defquery`-generated functions. Checks the memo table for
  a cached result, validates stale entries, and re-executes when needed.

  The `query_fun` receives `(db, key)` and returns the query result.
  """
  @spec execute(Database.t(), atom(), term(), (Database.t(), term() -> term())) :: term()
  def execute(%Database{} = db, query_name, key, query_fun)
      when is_atom(query_name) and is_function(query_fun, 2) do
    query_key = {query_name, key}

    # When called nested (inside another query), record the dependency.
    record_dep(query_key)

    # Store the query function so re_execute can find it during validation.
    # This covers both the defquery path (also registered) and direct
    # execute/4 calls (test closures, ad-hoc queries).
    Process.put({__MODULE__, :query_fun, query_name}, query_fun)

    result =
      case Database.query_definition(db, query_name) do
        %{boundary: {module, timeout, fallback}} ->
          bounded(db, query_name, key, query_fun, {module, timeout, fallback})

        _ ->
          resolve(db, query_name, key, query_fun)
      end

    propagate_durability(db, query_key)
    result
  end

  defp resolve(db, query_name, key, query_fun) do
    query_key = {query_name, key}
    current_rev = Revision.current(db.revision)

    result =
      cond do
        Validation.current?(db, query_key, current_rev) ->
          serve(db, query_name, key, query_key, current_rev, query_fun)

        Memo.verification_state(db, query_key) == :miss ->
          Telemetry.cache_miss(Database.id(db), query_name, key, current_rev)
          compute(db, query_name, key, query_key, current_rev, query_fun, :new)

        revalidate_by_execution?(db, query_name) ->
          compute(db, query_name, key, query_key, current_rev, query_fun, :replace)

        true ->
          case Validation.validate(db, query_key, &ensure_up_to_date/2) do
            :valid -> serve(db, query_name, key, query_key, current_rev, query_fun)
            :stale -> compute(db, query_name, key, query_key, current_rev, query_fun, :replace)
          end
      end

    result
  end

  defp revalidate_by_execution?(db, name),
    do: match?(%{revalidate: :execute}, Database.query_definition(db, name))

  # Ownership spans validation as well as computation: a timeout is one shared
  # outcome, never a second caller overwriting an already-published success.
  defp bounded(db, name, key, fun, policy) do
    query_key = {name, key}

    stack =
      case get_context() do
        nil -> []
        ctx -> ctx.query_stack
      end

    Cycle.check!(%Context{db: db, query_stack: stack}, query_key)

    case current_value(db, query_key) do
      {:ok, value} ->
        value

      :missing ->
        case claim_dedup(db, query_key) do
          :wait ->
            bounded(db, name, key, fun, policy)

          :claimed ->
            Cancellation.register_task(db, query_key, self())

            try do
              bounded_owned(db, name, key, fun, policy, stack)
            after
              Cancellation.unregister_task(db, query_key)
              release_dedup(db, query_key)
            end
        end
    end
  end

  defp bounded_owned(db, name, key, fun, {module, timeout_fun, fallback}, stack) do
    query_key = {name, key}

    case current_value(db, query_key) do
      {:ok, value} ->
        value

      :missing ->
        timeout = apply(module, timeout_fun, [])
        functions = for {{__MODULE__, :query_fun, _} = k, v} <- Process.get(), do: {k, v}

        Scope.run(db, timeout, fn ->
          Enum.each(functions, fn {k, v} -> Process.put(k, v) end)
          put_context(%Context{db: db, query_stack: stack})
          Process.put(@boundary_key, {db.memo_table, query_key})

          case Database.query_definition(db, name) do
            %{around_demand: {wrapper, function}} ->
              apply(wrapper, function, [db, name, key, fn -> resolve(db, name, key, fun) end])

            _ ->
              resolve(db, name, key, fun)
          end
        end)
        |> bounded_result(db, name, key, module, fallback)
    end
  end

  defp bounded_result({:ok, value}, _db, _name, _key, _module, _fallback), do: value

  defp bounded_result(:timeout, db, name, key, module, fallback) do
    query_key = {name, key}
    # The worker may have committed just before the deadline. Never replace a
    # value already established at this revision, even if its blob is missing.
    case current_value(db, query_key) do
      {:ok, value} ->
        value

      :missing ->
        revision = Revision.current(db.revision)

        case Memo.verification_state(db, query_key) do
          {:ok, ^revision, _} ->
            exit({:timeout, query_key})

          _ ->
            old = Process.put(@boundary_key, {db.memo_table, query_key})

            try do
              compute(
                db,
                name,
                key,
                query_key,
                revision,
                fn db, key -> apply(module, fallback, [db, key]) end,
                :replace
              )
            after
              if old, do: Process.put(@boundary_key, old), else: Process.delete(@boundary_key)
            end
        end
    end
  end

  defp current_value(db, {name, key} = query_key) do
    revision = Revision.current(db.revision)

    with true <- Validation.current?(db, query_key, revision),
         {:ok, changed, value} <- served_value(db, query_key) do
      Telemetry.cache_hit(Database.id(db), name, key, revision, changed, revision)
      {:ok, value}
    else
      _ -> :missing
    end
  end

  # A valid entry's value, or — when its value was held by a blob that is
  # gone — the value computed again, transparently: the entry is up to
  # date, only its value is missing, so it keeps its `changed_at` when the
  # value comes back the same.
  defp serve(db, query_name, key, query_key, current_rev, query_fun) do
    case served_value(db, query_key) do
      {:ok, changed_at, value} ->
        Telemetry.cache_hit(
          Database.id(db),
          query_name,
          key,
          current_rev,
          changed_at,
          current_rev
        )

        value

      :missing ->
        Telemetry.blob_missing(Database.id(db), query_name, key, current_rev)
        compute(db, query_name, key, query_key, current_rev, query_fun, :reload)
    end
  end

  @doc """
  Calls a derived query from within a query body.

  Records a dependency on the called query and dispatches to the
  registered query function. Executes inline (same process).
  """
  @spec query(Database.t(), atom(), term()) :: term()
  def query(%Database{} = db, query_name, key) when is_atom(query_name) do
    # Dep recording and durability propagation are handled by execute/4,
    # which is called by the dispatched defquery wrapper.
    dispatch_query(db, query_name, key)
  end

  @doc """
  Reads a query's registered code version and records a dependency on it.

  Returns nil when the query has no code version. A change invalidates the
  caller even when it never requested the query's value. This lets a cached
  aggregate depend on the code of computations it bypasses.
  """
  @spec query_code(Database.t(), atom()) :: binary() | nil
  def query_code(%Database{} = db, name) when is_atom(name) do
    version = Database.code_version(db, name)
    record_dep({:query_code, name, version})
    version
  end

  @doc """
  Calls a derived query, short-circuiting on errors.

  Like `query/3`, but if the result matches `{:error, reason}`, throws
  a `{:roux_query_error, reason}` that is automatically caught by the
  enclosing `defquery` and converted back to `{:error, reason}`.

  This eliminates nested `case` statements for error propagation:

      # Instead of:
      case Roux.Runtime.query(db, :typecheck, uri) do
        {:ok, types} -> use(types)
        {:error, _} = err -> err
      end

      # Write:
      {:ok, types} = Roux.Runtime.query!(db, :typecheck, uri)
      use(types)

  """
  @spec query!(Database.t(), atom(), term()) :: term()
  def query!(%Database{} = db, query_name, key) when is_atom(query_name) do
    case query(db, query_name, key) do
      {:error, reason} -> throw({:roux_query_error, reason})
      result -> result
    end
  end

  @doc """
  Reads an input value from within a query body.

  Records a dependency on the input and tracks its durability level
  in the current context for the durability optimization.
  """
  @spec input(Database.t(), atom(), term()) :: term()
  def input(%Database{} = db, input_name, key) when is_atom(input_name) do
    query_key = {:input, input_name, key}
    record_dep(query_key)
    track_input_durability(db, input_name, query_key)

    Roux.Input.get(db, input_name, key)
  end

  @doc """
  Reads an input value, or `default` when the key has none.

  An unset key is a dependency like a set one: the reader records that
  the input was absent, and setting it later invalidates the reader
  (`Roux.Validation`). While it stays unset the reader validates as
  fresh — where reading `Roux.Input.exists?/3` first and depending on the
  input only when it is set would leave a reader that never learns it
  was set, and depending on an unset input always would re-run the
  reader on every validation.

  ## Options

    * `:default` — the value of an unset key. Without it, behaves as
      `input/3` (raising `Roux.Input.NotSetError` on an unset key).
  """
  @spec input(Database.t(), atom(), term(), keyword()) :: term()
  def input(%Database{} = db, input_name, key, opts) when is_atom(input_name) and is_list(opts) do
    opts = Keyword.validate!(opts, [:default])

    case Keyword.fetch(opts, :default) do
      :error ->
        input(db, input_name, key)

      {:ok, default} ->
        query_key = {:input, input_name, key}

        case Roux.Input.fetch(db, input_name, key) do
          {:ok, value} ->
            record_dep(query_key)
            track_input_durability(db, input_name, query_key)
            value

          :error ->
            record_dep({:input_absent, input_name, key})
            track_input_durability(db, input_name, query_key)
            default
        end
    end
  end

  @doc """
  Reads an input value, short-circuiting on missing keys.

  Like `input/3`, but if the key has not been set, throws a
  `{:roux_query_error, reason}` that is automatically caught by the
  enclosing `defquery` and converted to `{:error, reason}`.
  """
  @spec input!(Database.t(), atom(), term()) :: term()
  def input!(%Database{} = db, input_name, key) when is_atom(input_name) do
    query_key = {:input, input_name, key}
    record_dep(query_key)
    track_input_durability(db, input_name, query_key)

    case Roux.Input.fetch(db, input_name, key) do
      {:ok, value} -> value
      :error -> throw({:roux_query_error, {:input_not_set, input_name, key}})
    end
  end

  @doc """
  Runs `fun` with dependency recording and durability propagation
  suppressed for the ENCLOSING query.

  Nested queries inside the block still execute normally — memoized,
  deduplicated, and cycle-checked in the same process — and record their
  own dependencies in their own memo entries. Only the caller's edges are
  discarded.

  For demand-driven warm-up whose exact dependencies are recorded
  separately: a compiler pre-loading hinted modules before compiling, with
  precise edges recorded from a tracer afterward. The hint list
  over-approximates, so tracking it would over-invalidate.

  By design the enclosing query does NOT re-run when an untracked-only
  input changes — that is the whole point, and it means the caller is
  responsible for recording the real edges some other way.

  The query stack is deliberately preserved, so a cycle through an
  untracked call still raises `Roux.Cycle.Error`.
  """
  @spec untracked((-> result)) :: result when result: var
  def untracked(fun) when is_function(fun, 0) do
    case get_context() do
      nil ->
        fun.()

      %Context{recorded_deps: deps, seen_deps: seen, min_durability: durability} ->
        try do
          fun.()
        after
          # Re-read: nested execution replaces the context struct, and the
          # parent's is restored by the time we get here. Rolling back these
          # fields discards everything recorded inside the block while
          # leaving query_stack (cycle detection) alone.
          case get_context() do
            nil ->
              :ok

            ctx ->
              put_context(%{
                ctx
                | recorded_deps: deps,
                  seen_deps: seen,
                  min_durability: durability
              })
          end
        end
    end
  end

  @doc """
  Demands independent queries concurrently, and returns their values in
  the order given.

  Inside a query body, the enclosing query records the whole fan-out as
  ONE dependency, `{:parallel, max_concurrency, keys}`, and validation
  brings its members up to date concurrently too, then checks each for
  a change — where a dependency per member would validate them one by
  one, re-executing stale ones in turn. The members run in processes
  linked to the caller, so cancelling the caller (`Roux.Cancellation`)
  takes them down with it; they carry the caller's query stack, so a
  cycle through them is detected. What a member raises is raised again
  here.

  ## Options

    * `:max_concurrency` — how many members run at once (default
      `System.schedulers_online/0`), for execution and validation alike;
    * `:timeout` — how long to wait for each member, `:infinity` by
      default: a member's own work bounds itself.
  """
  @spec parallel(Database.t(), [{atom(), term()}], keyword()) :: [term()]
  def parallel(%Database{} = db, queries, opts \\ []) when is_list(queries) do
    opts = Keyword.validate!(opts, [:max_concurrency, timeout: :infinity])

    max_concurrency = Keyword.get_lazy(opts, :max_concurrency, &System.schedulers_online/0)

    unless is_integer(max_concurrency) and max_concurrency > 0 do
      raise ArgumentError,
            ":max_concurrency must be a positive integer, got: #{inspect(max_concurrency)}"
    end

    parent_ctx = get_context()
    parent_stack = if parent_ctx, do: parent_ctx.query_stack, else: []

    results =
      fan_out(queries, max_concurrency, Keyword.fetch!(opts, :timeout), fn {query_name, key} ->
        put_context(%Context{db: db, query_stack: parent_stack})
        value = query(db, query_name, key)
        final_ctx = get_context()
        {value, final_ctx.created_entities, final_ctx.min_durability}
      end)

    merge_parallel_results(results, parent_ctx, {:parallel, max_concurrency, queries})
  end

  # Runs `fun` over `items` in processes linked to the caller, at most
  # `max_concurrency` at a time, and returns the results in order. What a
  # worker raises is caught there and raised again here, so a failure is
  # the caller's to rescue, as it would be run inline.
  #
  # Not `Task.async_stream/3`: its monitor process and per-task
  # bookkeeping put hundreds of scheduling points into every fan-out,
  # beyond what Concuerror can explore of a group validation. And a
  # worker here unlinks itself before it exits normally, so a caller that
  # traps exits (an LSP server) gets no `:EXIT` message per member. A
  # worker killed from outside (`Roux.Cancellation`) takes the caller
  # down, as the link would: its monitor says so.
  defp fan_out(items, max_concurrency, timeout, fun) do
    caller = self()
    ref = make_ref()
    {now, later} = items |> Enum.with_index() |> Enum.split(max_concurrency)
    running = Map.new(now, &start_worker(&1, caller, ref, fun))
    results = await_workers(running, later, %{}, {caller, ref, fun, timeout})

    for index <- 0..(length(items) - 1)//1 do
      case Map.fetch!(results, index) do
        {:ok, result} -> result
        {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
      end
    end
  end

  defp start_worker({item, index}, caller, ref, fun) do
    scope = Scope.current()

    {_pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          Scope.join(scope)

          result =
            try do
              {:ok, fun.(item)}
            catch
              kind, reason -> {:raised, kind, reason, __STACKTRACE__}
            end

          Process.unlink(caller)
          send(caller, {ref, index, result})
        end,
        [:link, :monitor]
      )

    {monitor, index}
  end

  defp await_workers(running, [], results, _job) when map_size(running) == 0, do: results

  defp await_workers(running, later, results, {caller, ref, fun, timeout} = job) do
    receive do
      {^ref, index, result} ->
        {monitor, _} = Enum.find(running, fn {_monitor, i} -> i == index end)
        Process.demonitor(monitor, [:flush])
        running = Map.delete(running, monitor)

        {running, later} =
          case later do
            [next | rest] ->
              {worker, i} = start_worker(next, caller, ref, fun)
              {Map.put(running, worker, i), rest}

            [] ->
              {running, []}
          end

        await_workers(running, later, Map.put(results, index, result), job)

      {:DOWN, monitor, :process, _pid, reason} when is_map_key(running, monitor) ->
        exit(reason)
    after
      timeout -> exit(:timeout)
    end
  end

  @doc """
  Creates or updates an entity from within a query body.

  Delegates to `Roux.Entity.create/4` with the current revision and
  records the entity in the context's `created_entities` for GC tracking.
  Returns the entity ID.
  """
  @spec create(Database.t(), module(), map()) :: Entity.entity_id()
  def create(%Database{} = db, module, attrs) when is_atom(module) and is_map(attrs) do
    current_rev = Revision.current(db.revision)
    entity_id = Entity.create(db, module, attrs, current_rev)
    record_created_entity(module, entity_id)
    entity_id
  end

  @doc """
  Reads an entity field from within a query body.

  Delegates to `Roux.Entity.field/4` and records a field-level dependency
  so the query is invalidated only when that specific field changes.
  """
  @spec field(Database.t(), module(), Entity.entity_id(), atom()) :: term()
  def field(%Database{} = db, module, entity_id, field_name)
      when is_atom(module) and is_integer(entity_id) and is_atom(field_name) do
    record_dep({:entity_field, module, entity_id, field_name})
    Entity.field(db, module, entity_id, field_name)
  end

  @doc """
  Reads all fields from an entity as a map.

  Calls `field/4` for each field, so a field-level dependency is recorded
  for every field. Use this when the consumer needs the whole entity; use
  `field/4` when it only needs a subset.
  """
  @spec read(Database.t(), module(), Entity.entity_id()) :: map()
  def read(%Database{} = db, module, entity_id)
      when is_atom(module) and is_integer(entity_id) do
    all_fields = module.__entity__(:all_fields)

    Map.new(all_fields, fn field_name ->
      {field_name, field(db, module, entity_id, field_name)}
    end)
  end

  @doc """
  Looks up an entity by identity key from within a query body.

  Non-interning lookup — does not record a dependency since the identity
  mapping is structural, not a data dependency.
  """
  @spec lookup(Database.t(), module(), tuple()) :: {:ok, Entity.entity_id()} | :error
  def lookup(%Database{} = db, module, identity_key)
      when is_atom(module) and is_tuple(identity_key) do
    Entity.lookup(db, module, identity_key)
  end

  @doc """
  Records that the value the running query returns names `digests` in
  the database's `Roux.Blob` store (files its body put there, say):
  while a manifest keeps the entry, it keeps them alive
  (`Roux.Blob.retain/3`). A value that only passes on digests an entry
  it read already holds need not hold them again — unless that entry is
  not kept (`store: :none`, `transient:`).

  Raises `ArgumentError` outside a query body.
  """
  @spec hold(Blob.digest() | [Blob.digest()]) :: :ok
  def hold(digests) do
    digests = List.wrap(digests)

    case get_context() do
      %Context{active_query: {_name, _key}} = ctx ->
        put_context(%{ctx | blobs: digests ++ ctx.blobs})
        :ok

      _outside ->
        raise ArgumentError, "Roux.Runtime.hold/1 called outside a query body"
    end
  end

  @doc """
  The code version of the query whose body is running (`Roux.Query`),
  or nil for a query without one: for a body that keys something of its
  own — an action-cache entry, a file it keeps — on the code computing
  it.

  Raises `ArgumentError` outside a query body.
  """
  @spec code_version() :: binary() | nil
  def code_version do
    case get_context() do
      %Context{active_query: {_name, _key}, code_version: version} ->
        version

      _outside ->
        raise ArgumentError, "Roux.Runtime.code_version/0 called outside a query body"
    end
  end

  @doc """
  Records that the current query depends on another query.

  Pure function that returns an updated context. Called internally
  by `query/3` and `input/3` via the process-dictionary helper. A
  dependency already recorded is not recorded again: an entry keeps each
  of its dependencies once, in the order they were first demanded, and
  validation walks each once.
  """
  @spec record_dependency(Context.t(), Memo.dependency()) :: Context.t()
  def record_dependency(%Context{recorded_deps: deps, seen_deps: seen} = ctx, dependency) do
    case seen do
      %{^dependency => true} ->
        ctx

      %{} ->
        %{ctx | recorded_deps: [dependency | deps], seen_deps: Map.put(seen, dependency, true)}
    end
  end

  # -- Private: ensure_up_to_date callback for Validation (D13) --

  # A fan-out's members are brought up to date as they were demanded:
  # concurrently, with the stack of whoever is validating.
  defp ensure_up_to_date(db, {:parallel, max_concurrency, members}) do
    stack =
      case get_context() do
        nil -> []
        ctx -> ctx.query_stack
      end

    _ =
      fan_out(members, max_concurrency, :infinity, fn member ->
        put_context(%Context{db: db, query_stack: stack})
        ensure_up_to_date(db, member)
      end)

    :ok
  end

  # Inputs have no computation to refresh. Validation reads their current
  # changed_at and durability immediately after this callback, including a
  # miss when an input was deleted.
  defp ensure_up_to_date(_db, {:input, _name, _key}), do: :ok

  defp ensure_up_to_date(db, query_key) do
    current_rev = Revision.current(db.revision)

    # Shared dependencies occur once per incoming edge. As in execute/4,
    # an entry already checked this revision needs no validation span.
    if Validation.current?(db, query_key, current_rev) do
      :ok
    else
      case execute_before_validation?(db, query_key) do
        true ->
          re_execute(db, query_key)

        false ->
          case Validation.validate(db, query_key, &ensure_up_to_date/2) do
            :valid -> :ok
            :stale -> re_execute(db, query_key)
          end
      end
    end
  end

  defp execute_before_validation?(db, {name, _key}) when is_atom(name) do
    case Database.query_definition(db, name) do
      %{boundary: {_, _, _}} -> true
      %{revalidate: :execute} -> true
      _ -> false
    end
  end

  defp execute_before_validation?(_db, _key), do: false

  defp re_execute(db, {query_name, key}) do
    case Process.get({__MODULE__, :query_fun, query_name}) do
      fun when is_function(fun) ->
        execute(db, query_name, key, fun)

      nil ->
        %{module: mod, function: fun} = lookup_query!(db, query_name)
        apply(mod, fun, [db, key])
    end

    :ok
  end

  # -- Private: computation --

  # `mode` is `:replace` when a stored entry went stale, `:new` when there
  # was none, and `:reload` when a valid entry's blob-held value was gone.
  defp compute(db, query_name, key, query_key, current_rev, query_fun, mode) do
    parent_ctx = get_context()
    parent_stack = if parent_ctx, do: parent_ctx.query_stack, else: []

    # Cycle detection must happen before dedup to prevent self-deadlock.
    check_ctx = %Context{db: db, query_stack: parent_stack}
    Cycle.check!(check_ctx, query_key)

    job = %{
      db: db,
      query_name: query_name,
      key: key,
      query_key: query_key,
      current_rev: current_rev,
      query_fun: query_fun,
      mode: mode,
      parent_stack: parent_stack
    }

    if Process.get(@boundary_key) == {db.memo_table, query_key} do
      do_compute(job)
    else
      compute_claimed(job)
    end
  end

  defp compute_claimed(%{db: db, query_key: query_key} = job) do
    case claim_dedup(db, query_key) do
      :claimed ->
        Cancellation.register_task(db, query_key, self())

        try do
          do_compute(job)
        after
          Cancellation.unregister_task(db, query_key)
          release_dedup(db, query_key)
        end

      :wait ->
        # Another process computed it. Re-check the memo.
        execute(db, job.query_name, job.key, job.query_fun)
    end
  end

  defp do_compute(job) do
    %{
      db: db,
      query_name: query_name,
      key: key,
      query_key: query_key,
      current_rev: current_rev,
      query_fun: query_fun,
      mode: mode,
      parent_stack: parent_stack
    } = job

    dependency_token = Dependencies.snapshot(db)
    current_rev = if db.dependencies, do: Revision.current(db.revision), else: current_rev
    prior_proven? = Dependencies.status(db, query_key) != :stale

    # What the entry being replaced says, read under the claim: no other
    # computation of this key can replace it until the claim is released,
    # so it is still the stored entry when the new one is written. Its
    # value is not read here — only an equal hash needs it (see
    # `compare_value/5`), and a restored value would be decoded for nothing.
    prior =
      case mode do
        :new -> nil
        _replace_or_reload -> prior_state(db, query_key)
      end

    # What the query is registered with: its code version, and how a
    # manifest keeps its entries. Nil for a closure run by name alone.
    definition = Database.query_definition(db, query_name)

    # Fresh context for this query's execution.
    exec_ctx = %Context{
      db: db,
      active_query: query_key,
      query_stack: parent_stack ++ [query_key],
      recorded_deps: [],
      seen_deps: %{},
      created_entities: [],
      min_durability: :high,
      code_version: definition && Map.get(definition, :code_version)
    }

    Telemetry.query_start(Database.id(db), query_name, key, current_rev)
    start_time = System.monotonic_time()

    old_ctx = put_context(exec_ctx)

    try do
      value = query_fun.(db, key)
      final_ctx = get_context()

      duration = System.monotonic_time() - start_time
      hash = :erlang.phash2(value)

      # Early cutoff: if value unchanged, keep the old changed_at.
      {unchanged?, encoded} =
        if prior_proven?,
          do: compare_value(db, query_key, prior, hash, value),
          else: {false, nil}

      changed_at =
        if unchanged? do
          Telemetry.early_cutoff(Database.id(db), query_name, key, current_rev, prior.changed_at)
          prior.changed_at
        else
          current_rev
        end

      entry = %Entry{
        value: value,
        hash: hash,
        changed_at: changed_at,
        verified_at: current_rev,
        dependencies: Enum.reverse(final_ctx.recorded_deps),
        durability: final_ctx.min_durability,
        output_entities: final_ctx.created_entities,
        code_version: exec_ctx.code_version,
        persist: persist(definition, value),
        blobs: Enum.uniq(final_ctx.blobs)
      }

      {same_persistence?, preserve_storage?} =
        publication_storage(db, query_key, prior, entry, {unchanged?, encoded}, mode)

      generation = Memo.publish(db, query_key, entry, preserve_storage?, dependency_token)

      if encoded, do: Memo.remember_encoding(db, query_key, generation, value, encoded)

      unless same_persistence? and preserve_storage?, do: Database.note_write(db)

      cache_value(db, query_key, changed_at, generation, value)

      # Update entity refcounts for the output entity diff (D15).
      old_entities = if prior, do: prior.output_entities, else: []
      GC.sweep_query(db, query_key, old: old_entities, new: entry.output_entities)

      Telemetry.query_stop(Database.id(db), query_name, key, current_rev, duration, hash)

      value
    rescue
      error ->
        duration = System.monotonic_time() - start_time

        Telemetry.query_exception(
          Database.id(db),
          query_name,
          key,
          current_rev,
          duration,
          :error,
          error
        )

        reraise error, __STACKTRACE__
    after
      restore_context(old_ctx)
    end
  end

  # How a manifest keeps the entry (`Roux.Memo.Entry`): its query's
  # `store:`, unless its `transient:` predicate accepts the value.
  defp persist(nil, _value), do: :inline

  defp persist(definition, value) do
    case Map.get(definition, :transient) do
      {module, function} ->
        if apply(module, function, [value]) == true,
          do: :transient,
          else: Map.get(definition, :store, :inline)

      nil ->
        Map.get(definition, :store, :inline)
    end
  end

  # Rechecking an identical compact proof need not write a manifest. For
  # packed values, first verify the old locator; a missing or damaged pack
  # must publish live storage and make the repair durable on checkpoint.
  defp publication_storage(db, key, prior, entry, {unchanged?, encoded}, mode) do
    same_persistence? =
      unchanged? and mode != :reload and
        Memo.same_persistence?(db, key, prior.generation, entry)

    preserve_storage? =
      unchanged? and mode != :reload and
        (not packed_prior?(prior) or
           (same_persistence? and packed_available?(db, prior, encoded)))

    {same_persistence?, preserve_storage?}
  end

  defp prior_state(db, query_key) do
    case Memo.prior_state(db, query_key) do
      {:ok, hash, changed_at, output_entities} ->
        %{
          hash: hash,
          changed_at: changed_at,
          generation: Memo.generation(db, query_key),
          output_entities: output_entities,
          held: Memo.held_digest(db, query_key),
          locator: Memo.held_locator(db, query_key)
        }

      :miss ->
        nil
    end
  end

  # Whether `value` is the value the replaced entry holds. The hashes
  # decide most cases; only equal ones read the stored value to compare —
  # or, for a value held by a blob, compare the new value's digest with
  # its own, reading nothing (and putting the bytes back, in case the
  # blob is what went missing). A stored entry that went away meanwhile
  # (a GC sweep) counts as a change, which recomputes dependents rather
  # than serving them stale.
  defp compare_value(db, query_key, %{hash: hash, held: held} = prior, hash, value) do
    case held do
      {:ok, digest} ->
        {new_digest, encoded} = Blob.encode_term(value)

        equal? =
          new_digest == digest and
            (packed_prior?(prior) or held_again?(db, digest, encoded))

        {equal?, {new_digest, encoded}}

      :none ->
        {match?({:ok, ^value}, Memo.fetch_value(db, query_key)), nil}
    end
  end

  defp compare_value(_db, _query_key, _prior, _hash, _value), do: {false, nil}

  # A packed locator may have vanished since restore. Keep equality's old
  # changed_at, but publish the live value and reusable bytes independently of
  # that physical pack. The next checkpoint chooses its new storage location.
  defp packed_prior?(%{locator: {:ok, {:packed, _, _, _, _}}}), do: true
  defp packed_prior?(_), do: false

  defp packed_available?(db, %{locator: {:ok, locator}}, {_digest, bytes}) do
    Value.load_bytes(db.blob, locator) == {:ok, bytes}
  end

  defp held_again?(%Database{blob: %Blob{} = store}, digest, encoded),
    do: match?({:ok, _}, Blob.put_encoded_term(store, digest, encoded))

  defp held_again?(_db_without_store, _digest, _encoded), do: false

  # -- Private: dedup --

  # Two processes demanding the same key must not both compute it. The
  # loser waits for the winner to FINISH.
  #
  # It used to wait for the winner to DIE — the only wakeup was a monitor
  # `:DOWN`. That is indistinguishable from completion when the computing
  # process is a short-lived Task, which is what the tests and the original
  # design assumed. It is a permanent hang when the computing process is
  # long-lived: a GenServer, an LSP loop, an IEx session. Planchette hit
  # exactly this and had to serialise its query fan-out around it.
  #
  # The claimant now publishes completion. The ordering is what makes it
  # race-free: a waiter registers itself and THEN re-checks the claim row,
  # while the claimant deletes the claim row and THEN reads the waiter list.
  # So if the row is still there after registering, the claimant has not yet
  # read the list and is guaranteed to see us; and if it is gone, the result
  # is already in the memo and there is nothing to wait for.
  defp claim_dedup(db, query_key) do
    case :ets.insert_new(db.dedup_table, {query_key, self()}) do
      true -> :claimed
      false -> wait_for_claimant(db, query_key)
    end
  end

  defp wait_for_claimant(db, query_key) do
    case :ets.lookup(db.dedup_table, query_key) do
      [{^query_key, pid}] ->
        ref = Process.monitor(pid)
        :ets.insert(db.dedup_waiters, {query_key, self()})

        if :ets.member(db.dedup_table, query_key) do
          await_claimant(query_key, pid, ref)
        end

        Process.demonitor(ref, [:flush])
        forget_waiter(db, query_key)
        drain_completion(query_key)
        reap_dead_claim(db, query_key, pid)
        :wait

      [] ->
        # Claimed and released between insert_new and lookup. Retry rather
        # than wait: whoever held it is gone, so this key is free again.
        claim_dedup(db, query_key)
    end
  end

  defp await_claimant(query_key, pid, ref) do
    receive do
      {:roux_computed, ^query_key} -> :ok
      # An abnormal exit leaves no completion message. The claimant's
      # `after` block never ran, so its dedup row may still be there — the
      # caller re-enters execute/4, finds no memo entry, and claims it.
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp forget_waiter(db, query_key) do
    :ets.delete_object(db.dedup_waiters, {query_key, self()})
  end

  # A claimant that dies abnormally never runs its `after` block, so its
  # claim row outlives it. Without this the woken waiter re-enters
  # `execute/4`, misses the memo, fails `insert_new` against the dead
  # claimant's row, monitors a dead pid, gets an immediate `:noproc`, and
  # loops — forever, because nothing else ever removes that row.
  #
  # `delete_object/2` rather than `delete/2`: it removes only the exact
  # tuple, so a claim taken over by a live process in the meantime is left
  # alone.
  defp reap_dead_claim(db, query_key, pid) do
    unless Process.alive?(pid) do
      :ets.delete_object(db.dedup_table, {query_key, pid})
    end

    :ok
  end

  # A waiter that registered and then found the row already gone can still
  # be sent a completion message by a claimant that read the list first.
  # Leaving it in the mailbox would satisfy a later, unrelated wait on the
  # same key.
  defp drain_completion(query_key) do
    receive do
      {:roux_computed, ^query_key} -> :ok
    after
      0 -> :ok
    end
  end

  # Delete the claim BEFORE reading the waiter list — see claim_dedup/2.
  #
  # `lookup` + `delete` rather than the atomic `take/2`, because Concuerror
  # does not model `ets:take` and this is precisely the code its dedup
  # scenarios exist to explore. Losing the atomicity is safe: a waiter that
  # registers between the lookup and the delete gets dropped without a
  # message, but it registered AFTER the claim row was already deleted, so
  # its own re-check finds no claim and it returns immediately. The message
  # is the fast path; the re-check is the correctness guarantee.
  defp release_dedup(db, query_key) do
    :ets.delete(db.dedup_table, query_key)

    waiters = :ets.lookup(db.dedup_waiters, query_key)
    :ets.delete(db.dedup_waiters, query_key)

    Enum.each(waiters, fn {^query_key, pid} -> send(pid, {:roux_computed, query_key}) end)
    :ok
  end

  # -- Private: process dictionary context --

  defp get_context, do: Process.get(@context_key)

  defp put_context(ctx), do: Process.put(@context_key, ctx)

  defp restore_context(nil), do: Process.delete(@context_key)
  defp restore_context(old_ctx), do: Process.put(@context_key, old_ctx)

  defp record_dep(query_key) do
    case get_context() do
      nil -> :ok
      ctx -> put_context(record_dependency(ctx, query_key))
    end
  end

  defp record_created_entity(module, entity_id) do
    case get_context() do
      nil -> :ok
      ctx -> put_context(%{ctx | created_entities: [{module, entity_id} | ctx.created_entities]})
    end
  end

  # -- Private: durability propagation --

  defp track_input_durability(db, input_name, query_key) do
    case get_context() do
      nil ->
        :ok

      ctx ->
        durability = input_durability(db, input_name, query_key)
        put_context(%{ctx | min_durability: min_durability(ctx.min_durability, durability)})
    end
  end

  defp propagate_durability(db, query_key) do
    case get_context() do
      nil ->
        :ok

      ctx ->
        case Memo.durability(db, query_key) do
          {:ok, dur} ->
            put_context(%{ctx | min_durability: min_durability(ctx.min_durability, dur)})

          :miss ->
            :ok
        end
    end
  end

  # Per-KEY durability, falling back to the input definition's default.
  defp input_durability(db, input_name, query_key) do
    case Memo.durability(db, query_key) do
      {:ok, durability} when not is_nil(durability) -> durability
      _ -> lookup_input_durability(db, input_name)
    end
  end

  # -- Private: served values --

  defp served_value(%Database{memo_table: table} = db, query_key) do
    {:ok, changed_at} = Memo.changed_at(db, query_key)
    generation = Memo.generation(db, query_key)

    case Process.get({@values_key, table, query_key}) do
      {^changed_at, ^generation, value} ->
        {:ok, changed_at, value}

      _ ->
        case Memo.fetch_versioned_value(db, query_key) do
          {:ok, changed_at, generation, value} ->
            cache_value(db, query_key, changed_at, generation, value)
            {:ok, changed_at, value}

          _missing ->
            :missing
        end
    end
  end

  defp cache_value(%Database{memo_table: table}, query_key, changed_at, generation, value) do
    Process.put(
      {@values_key, table, query_key},
      {changed_at, generation, value}
    )

    :ok
  end

  @doc """
  Drops the values this process cached while serving `db`'s queries.

  A process that serves queries keeps every value it served on its own
  heap until the key is recomputed or the process exits. A long-lived
  process that shuts a database down should call this alongside
  `Roux.Database.shutdown/1`.
  """
  @spec drop_cached_values(Database.t()) :: :ok
  def drop_cached_values(%Database{memo_table: table}) do
    for {{@values_key, ^table, _query_key} = key, _} <- Process.get(), do: Process.delete(key)
    :ok
  end

  defp lookup_input_durability(%Database{input_registry: reg}, input_name) do
    case :ets.lookup(reg, input_name) do
      [{^input_name, opts}] -> Map.get(opts, :durability, :medium)
      [] -> :medium
    end
  end

  defp min_durability(:low, _), do: :low
  defp min_durability(_, :low), do: :low
  defp min_durability(:medium, _), do: :medium
  defp min_durability(_, :medium), do: :medium
  defp min_durability(:high, :high), do: :high

  # -- Private: query dispatch --

  defp dispatch_query(db, query_name, key) do
    %{module: mod, function: fun} = lookup_query!(db, query_name)
    apply(mod, fun, [db, key])
  end

  defp lookup_query!(%Database{query_registry: reg}, query_name) do
    case :ets.lookup(reg, query_name) do
      [{^query_name, definition}] -> definition
      [] -> raise ArgumentError, "query #{inspect(query_name)} is not registered"
    end
  end

  # -- Private: parallel merging --

  defp merge_parallel_results(results, nil, _group) do
    Enum.map(results, fn {value, _entities, _dur} -> value end)
  end

  defp merge_parallel_results(results, parent_ctx, {:parallel, _, members} = group) do
    {values, merged_ctx} =
      Enum.reduce(results, {[], parent_ctx}, fn {value, entities, dur}, {vals, ctx} ->
        ctx = %{
          ctx
          | created_entities: entities ++ ctx.created_entities,
            min_durability: min_durability(ctx.min_durability, dur)
        }

        {[value | vals], ctx}
      end)

    # One edge for the whole fan-out. What the members' tasks recorded
    # besides their own keys (dependencies their validation walked) is
    # theirs, and their entries hold it.
    merged_ctx =
      if members == [], do: merged_ctx, else: record_dependency(merged_ctx, group)

    put_context(merged_ctx)
    Enum.reverse(values)
  end
end
