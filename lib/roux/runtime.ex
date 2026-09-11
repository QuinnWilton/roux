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

  alias Roux.{Cancellation, Cycle, Database, Entity, GC, Memo, Revision, Telemetry, Validation}
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

      %Context{recorded_deps: deps, min_durability: durability} ->
        try do
          fun.()
        after
          # Re-read: nested execution replaces the context struct, and the
          # parent's is restored by the time we get here. Rolling back these
          # two fields discards everything recorded inside the block while
          # leaving query_stack (cycle detection) alone.
          case get_context() do
            nil -> :ok
            ctx -> put_context(%{ctx | recorded_deps: deps, min_durability: durability})
          end
        end
    end
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

    job = %{
      db: db,
      query_name: query_name,
      key: key,
      query_key: query_key,
      current_rev: current_rev,
      query_fun: query_fun,
      old_entry: old_entry,
      parent_stack: parent_stack
    }

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
        execute(db, query_name, key, query_fun)
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
      old_entry: old_entry,
      parent_stack: parent_stack
    } = job

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

      # Update entity refcounts for the output entity diff (D15).
      old_entities = if old_entry, do: old_entry.output_entities, else: []
      GC.sweep_query(db, query_key, old: old_entities, new: entry.output_entities)

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
        case Memo.get(db, query_key) do
          {:ok, %Entry{durability: dur}} ->
            put_context(%{ctx | min_durability: min_durability(ctx.min_durability, dur)})

          :miss ->
            :ok
        end
    end
  end

  # Per-KEY durability, falling back to the input definition's default.
  defp input_durability(db, input_name, query_key) do
    case Memo.get(db, query_key) do
      {:ok, %Entry{durability: durability}} when not is_nil(durability) -> durability
      _ -> lookup_input_durability(db, input_name)
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
