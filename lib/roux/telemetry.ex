defmodule Roux.Telemetry do
  @moduledoc """
  Structured event definitions for observability and debugging.

  Emits `:telemetry` events for all significant framework operations.
  Essential for answering "why did this query re-execute?" and "why
  didn't this query re-execute?"

  All events are prefixed with `[:roux, ...]`. Helper functions enforce
  consistent metadata shapes for each event type.

  ## Event reference

  ### Query lifecycle

  - `[:roux, :query, :start]` — query execution begins
  - `[:roux, :query, :stop]` — query execution completes
  - `[:roux, :query, :exception]` — query execution raised

  ### Cache operations

  - `[:roux, :cache, :hit]` — memo entry is valid, no re-execution needed
  - `[:roux, :cache, :miss]` — no memo entry, must execute
  - `[:roux, :cache, :early_cutoff]` — value unchanged after re-execution

  ### Validation

  - `[:roux, :validation, :start]` — validation begins
  - `[:roux, :validation, :stop]` — validation completes
  - `[:roux, :validation, :durability_skip]` — validation skipped via durability

  ### Other operations

  - `[:roux, :input, :set]` — input value set or modified
  - `[:roux, :input, :delete]` — input value removed
  - `[:roux, :cycle, :detected]` — dependency cycle detected
  - `[:roux, :cancel, :task]` — query task cancelled
  - `[:roux, :gc, :sweep]` — garbage collection sweep completed
  - `[:roux, :intern, :new]` — new value interned
  """

  @doc """
  Wraps `:telemetry.span/3` with the `[:roux | event_prefix]` prefix.

  Executes `fun`, emitting start and stop (or exception) events
  automatically.
  """
  @spec span([atom()], map(), (-> {term(), map()})) :: term()
  def span(event_prefix, metadata, fun) when is_list(event_prefix) and is_map(metadata) do
    :telemetry.span([:roux | event_prefix], metadata, fun)
  end

  @doc """
  Emits a single `:telemetry` event with the `[:roux | event_name]` prefix.
  """
  @spec event([atom()], map(), map()) :: :ok
  def event(event_name, measurements \\ %{}, metadata)
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute([:roux | event_name], measurements, metadata)
  end

  # -- Query lifecycle --

  @doc "Emits `[:roux, :query, :start]`."
  @spec query_start(atom(), term(), non_neg_integer()) :: :ok
  def query_start(query_name, key, revision) do
    event([:query, :start], %{system_time: System.system_time()}, %{
      query_name: query_name,
      key: key,
      revision: revision
    })
  end

  @doc "Emits `[:roux, :query, :stop]`."
  @spec query_stop(atom(), term(), non_neg_integer(), non_neg_integer(), term()) :: :ok
  def query_stop(query_name, key, revision, duration, result_hash) do
    event([:query, :stop], %{duration: duration}, %{
      query_name: query_name,
      key: key,
      revision: revision,
      result_hash: result_hash
    })
  end

  @doc "Emits `[:roux, :query, :exception]`."
  @spec query_exception(atom(), term(), non_neg_integer(), non_neg_integer(), atom(), term()) ::
          :ok
  def query_exception(query_name, key, revision, duration, kind, reason) do
    event([:query, :exception], %{duration: duration}, %{
      query_name: query_name,
      key: key,
      revision: revision,
      kind: kind,
      reason: reason
    })
  end

  # -- Cache operations --

  @doc "Emits `[:roux, :cache, :hit]`."
  @spec cache_hit(atom(), term(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: :ok
  def cache_hit(query_name, key, revision, changed_at, verified_at) do
    event([:cache, :hit], %{}, %{
      query_name: query_name,
      key: key,
      revision: revision,
      changed_at: changed_at,
      verified_at: verified_at
    })
  end

  @doc "Emits `[:roux, :cache, :miss]`."
  @spec cache_miss(atom(), term(), non_neg_integer()) :: :ok
  def cache_miss(query_name, key, revision) do
    event([:cache, :miss], %{}, %{
      query_name: query_name,
      key: key,
      revision: revision
    })
  end

  @doc "Emits `[:roux, :cache, :early_cutoff]`."
  @spec early_cutoff(atom(), term(), non_neg_integer(), non_neg_integer()) :: :ok
  def early_cutoff(query_name, key, revision, changed_at) do
    event([:cache, :early_cutoff], %{}, %{
      query_name: query_name,
      key: key,
      revision: revision,
      changed_at: changed_at
    })
  end

  # -- Validation --

  @doc "Emits `[:roux, :validation, :start]`."
  @spec validation_start(atom(), term(), non_neg_integer()) :: :ok
  def validation_start(query_name, key, revision) do
    event([:validation, :start], %{system_time: System.system_time()}, %{
      query_name: query_name,
      key: key,
      revision: revision
    })
  end

  @doc "Emits `[:roux, :validation, :stop]`."
  @spec validation_stop(atom(), term(), non_neg_integer(), non_neg_integer(), :valid | :stale) ::
          :ok
  def validation_stop(query_name, key, revision, duration, result)
      when result in [:valid, :stale] do
    event([:validation, :stop], %{duration: duration}, %{
      query_name: query_name,
      key: key,
      revision: revision,
      result: result
    })
  end

  @doc "Emits `[:roux, :validation, :durability_skip]`."
  @spec durability_skip(atom(), term(), atom(), non_neg_integer()) :: :ok
  def durability_skip(query_name, key, durability, revision) do
    event([:validation, :durability_skip], %{}, %{
      query_name: query_name,
      key: key,
      durability: durability,
      revision: revision
    })
  end

  # -- Other operations --

  @doc "Emits `[:roux, :input, :set]`."
  @spec input_set(atom(), term(), non_neg_integer(), atom()) :: :ok
  def input_set(input_name, key, revision, durability) do
    event([:input, :set], %{}, %{
      input_name: input_name,
      key: key,
      revision: revision,
      durability: durability
    })
  end

  @doc "Emits `[:roux, :input, :delete]`."
  @spec input_delete(atom(), term(), non_neg_integer(), atom()) :: :ok
  def input_delete(input_name, key, revision, durability) do
    event([:input, :delete], %{}, %{
      input_name: input_name,
      key: key,
      revision: revision,
      durability: durability
    })
  end

  @doc "Emits `[:roux, :cycle, :detected]`."
  @spec cycle_detected(atom(), term(), [term()]) :: :ok
  def cycle_detected(query_name, key, stack) do
    event([:cycle, :detected], %{}, %{
      query_name: query_name,
      key: key,
      stack: stack
    })
  end

  @doc "Emits `[:roux, :cancel, :task]`."
  @spec cancel_task(atom(), term(), term()) :: :ok
  def cancel_task(query_name, key, reason) do
    event([:cancel, :task], %{}, %{
      query_name: query_name,
      key: key,
      reason: reason
    })
  end

  @doc "Emits `[:roux, :gc, :sweep]`."
  @spec gc_sweep(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          :ok
  def gc_sweep(duration, memo_entries_removed, entities_removed, revision) do
    event(
      [:gc, :sweep],
      %{
        duration: duration,
        memo_entries_removed: memo_entries_removed,
        entities_removed: entities_removed
      },
      %{revision: revision}
    )
  end

  @doc "Emits `[:roux, :intern, :new]`."
  @spec intern_new(atom(), pos_integer(), non_neg_integer()) :: :ok
  def intern_new(table_name, id, value_size) do
    event([:intern, :new], %{}, %{
      table_name: table_name,
      id: id,
      value_size: value_size
    })
  end
end
