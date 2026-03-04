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
  `query/3` executes inline. `parallel/2` fans out and merges deps.

  See D3, D13, D14 for design rationale.
  """

  alias Roux.{Cancellation, Cycle, Database, Memo, Revision, Telemetry, Validation}
  alias Roux.Memo.Entry
  alias Roux.Runtime.Context

  @context_key {__MODULE__, :context}

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

    current_rev = Revision.current(db.revision)

    result =
      case Memo.get(db, query_key) do
        {:ok, %Entry{verified_at: ^current_rev} = entry} ->
          Telemetry.cache_hit(query_name, key, current_rev, entry.changed_at, entry.verified_at)
          entry.value

        {:ok, %Entry{} = old_entry} ->
          case Validation.validate(db, query_key, &ensure_up_to_date/2) do
            :valid ->
              {:ok, fresh} = Memo.get(db, query_key)

              Telemetry.cache_hit(
                query_name,
                key,
                current_rev,
                fresh.changed_at,
                fresh.verified_at
              )

              fresh.value

            :stale ->
              compute(db, query_name, key, query_key, current_rev, query_fun, old_entry)
          end

        :miss ->
          Telemetry.cache_miss(query_name, key, current_rev)
          compute(db, query_name, key, query_key, current_rev, query_fun, nil)
      end

    # Propagate child's durability to parent context when nested.
    propagate_durability(db, query_key)

    result
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
  Reads an input value from within a query body.

  Records a dependency on the input and tracks its durability level
  in the current context for the durability optimization.
  """
  @spec input(Database.t(), atom(), term()) :: term()
  def input(%Database{} = db, input_name, key) when is_atom(input_name) do
    query_key = {:input, input_name, key}
    record_dep(query_key)
    track_input_durability(db, input_name)

    Roux.Input.get(db, input_name, key)
  end

  @doc """
  Executes multiple independent queries concurrently.

  Spawns a task per query, collects results, and merges all recorded
  dependencies, created entities, and durability levels back into the
  parent context. Returns results in the same order as the input list.
  """
  @spec parallel(Database.t(), [{atom(), term()}]) :: [term()]
  def parallel(%Database{} = db, queries) when is_list(queries) do
    parent_ctx = get_context()
    parent_stack = if parent_ctx, do: parent_ctx.query_stack, else: []

    tasks =
      Enum.map(queries, fn {query_name, key} ->
        Task.async(fn ->
          ctx = %Context{db: db, query_stack: parent_stack}
          put_context(ctx)

          value = query(db, query_name, key)
          final_ctx = get_context()

          {value, final_ctx.recorded_deps, final_ctx.created_entities, final_ctx.min_durability}
        end)
      end)

    results = Task.await_many(tasks)
    merge_parallel_results(results, parent_ctx)
  end

  @doc """
  Records that the current query depends on another query.

  Pure function that returns an updated context. Called internally
  by `query/3` and `input/3` via the process-dictionary helper.
  """
  @spec record_dependency(Context.t(), Memo.query_key()) :: Context.t()
  def record_dependency(%Context{} = ctx, query_key) do
    %{ctx | recorded_deps: [query_key | ctx.recorded_deps]}
  end

  # -- Private: ensure_up_to_date callback for Validation (D13) --

  defp ensure_up_to_date(db, query_key) do
    case Validation.validate(db, query_key, &ensure_up_to_date/2) do
      :valid -> :ok
      :stale -> re_execute(db, query_key)
    end
  end

  defp re_execute(_db, {:input, _input_name, _key}) do
    # Inputs are set externally and cannot be re-executed.
    # Staleness will propagate to the parent query.
    :ok
  end

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

  defp compute(db, query_name, key, query_key, current_rev, query_fun, old_entry) do
    parent_ctx = get_context()
    parent_stack = if parent_ctx, do: parent_ctx.query_stack, else: []

    # Cycle detection must happen before dedup to prevent self-deadlock.
    check_ctx = %Context{db: db, query_stack: parent_stack}
    Cycle.check!(check_ctx, query_key)

    case claim_dedup(db, query_key) do
      :claimed ->
        Cancellation.register_task(db, query_key, self())

        try do
          do_compute(
            db,
            query_name,
            key,
            query_key,
            current_rev,
            query_fun,
            old_entry,
            parent_stack
          )
        after
          Cancellation.unregister_task(db, query_key)
          :ets.delete(db.dedup_table, query_key)
        end

      :wait ->
        # Another process computed it. Re-check the memo.
        execute(db, query_name, key, query_fun)
    end
  end

  defp do_compute(db, query_name, key, query_key, current_rev, query_fun, old_entry, parent_stack) do
    # Fresh context for this query's execution.
    exec_ctx = %Context{
      db: db,
      active_query: query_key,
      query_stack: parent_stack ++ [query_key],
      recorded_deps: [],
      created_entities: [],
      min_durability: :high
    }

    Telemetry.query_start(query_name, key, current_rev)
    start_time = System.monotonic_time()

    old_ctx = put_context(exec_ctx)

    try do
      value = query_fun.(db, key)
      final_ctx = get_context()

      duration = System.monotonic_time() - start_time
      hash = :erlang.phash2(value)

      # Early cutoff: if value unchanged, keep the old changed_at.
      changed_at =
        case old_entry do
          %Entry{hash: ^hash, value: ^value} ->
            Telemetry.early_cutoff(query_name, key, current_rev, old_entry.changed_at)
            old_entry.changed_at

          _ ->
            current_rev
        end

      entry = %Entry{
        value: value,
        hash: hash,
        changed_at: changed_at,
        verified_at: current_rev,
        dependencies: Enum.reverse(final_ctx.recorded_deps),
        durability: final_ctx.min_durability,
        output_entities: final_ctx.created_entities
      }

      Memo.put(db, query_key, entry)
      Telemetry.query_stop(query_name, key, current_rev, duration, hash)

      value
    rescue
      error ->
        duration = System.monotonic_time() - start_time
        Telemetry.query_exception(query_name, key, current_rev, duration, :error, error)
        reraise error, __STACKTRACE__
    after
      restore_context(old_ctx)
    end
  end

  # -- Private: dedup --

  defp claim_dedup(db, query_key) do
    case :ets.insert_new(db.dedup_table, {query_key, self()}) do
      true ->
        :claimed

      false ->
        case :ets.lookup(db.dedup_table, query_key) do
          [{^query_key, pid}] ->
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, ^pid, _reason} -> :wait
            end

          [] ->
            # Entry was deleted between insert_new and lookup. Retry.
            claim_dedup(db, query_key)
        end
    end
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

  # -- Private: durability propagation --

  defp track_input_durability(db, input_name) do
    case get_context() do
      nil ->
        :ok

      ctx ->
        durability = lookup_input_durability(db, input_name)
        put_context(%{ctx | min_durability: min_durability(ctx.min_durability, durability)})
    end
  end

  defp propagate_durability(db, query_key) do
    case get_context() do
      nil ->
        :ok

      ctx ->
        case Memo.get(db, query_key) do
          {:ok, %Entry{durability: dur}} ->
            put_context(%{ctx | min_durability: min_durability(ctx.min_durability, dur)})

          :miss ->
            :ok
        end
    end
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

  defp merge_parallel_results(results, nil) do
    Enum.map(results, fn {value, _deps, _entities, _dur} -> value end)
  end

  defp merge_parallel_results(results, parent_ctx) do
    {values, merged_ctx} =
      Enum.reduce(results, {[], parent_ctx}, fn {value, deps, entities, dur}, {vals, ctx} ->
        ctx = %{
          ctx
          | recorded_deps: Enum.reverse(deps) ++ ctx.recorded_deps,
            created_entities: entities ++ ctx.created_entities,
            min_durability: min_durability(ctx.min_durability, dur)
        }

        {[value | vals], ctx}
      end)

    put_context(merged_ctx)
    Enum.reverse(values)
  end
end
