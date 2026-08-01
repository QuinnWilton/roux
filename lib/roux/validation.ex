defmodule Roux.Validation do
  @moduledoc """
  Determines whether a cached memo entry is still valid.

  The validation algorithm recursively checks dependencies to avoid
  recomputation when nothing has changed. Early cutoff is integrated:
  even after a dependency re-executes, if its value hasn't changed
  (`changed_at` stays old), downstream queries remain valid.

  ## The algorithm

  Four cases, checked in order:

  1. **No memo** — the query has never been computed. Return `:stale`.
  2. **Already validated** — `verified_at == current_rev`. Return `:valid`.
  3. **Durability skip** — no input at this query's durability level (or
     below) has changed since `verified_at`. Update `verified_at` and
     return `:valid` without walking dependencies.
  4. **Walk dependencies** — for each dependency, call `ensure_fn` to
     bring it up to date, then check its `changed_at`. First stale dep
     short-circuits to `:stale`. All clean → update `verified_at`,
     return `:valid`.

  ## Dependency inversion

  Validation accepts an `ensure_fn` callback rather than depending on
  Runtime directly. Runtime provides its `ensure_up_to_date/2` as the
  callback, breaking the compile-time dependency cycle (see D13).
  """

  alias Roux.Database
  alias Roux.{Entity, Memo, Revision, Telemetry}
  alias Roux.Memo.Entry

  @type ensure_fn :: (Database.t(), Memo.query_key() -> :ok)

  @doc """
  Validates whether a cached memo entry is still current.

  Returns `:valid` if the cached value can be reused, `:stale` if the
  query needs re-execution. Updates `verified_at` to the current revision
  as a side effect when the entry is valid.

  The `ensure_fn` callback is called for each dependency to bring it up
  to date before checking its `changed_at`. This is typically
  `Runtime.ensure_up_to_date/2`.
  """
  @spec validate(Database.t(), Memo.query_key(), ensure_fn()) :: :valid | :stale
  def validate(%Database{} = db, query_key, ensure_fn) when is_function(ensure_fn, 2) do
    {query_name, key} = decompose_query_key(query_key)
    current_rev = Revision.current(db.revision)

    Telemetry.validation_start(query_name, key, current_rev)
    start_time = System.monotonic_time()

    result = do_validate(db, query_key, current_rev, query_name, key, ensure_fn)

    duration = System.monotonic_time() - start_time
    Telemetry.validation_stop(query_name, key, current_rev, duration, result)

    result
  end

  # -- Private --

  defp do_validate(db, query_key, current_rev, query_name, key, ensure_fn) do
    case Memo.get(db, query_key) do
      # Case 1: no memo.
      :miss ->
        :stale

      # Case 2: already validated this revision.
      {:ok, %Entry{verified_at: ^current_rev}} ->
        :valid

      {:ok, %Entry{} = entry} ->
        # Case 3: durability skip.
        if Revision.last_changed_at_or_above(db.revision, entry.durability) <=
             entry.verified_at do
          Memo.update_verified(db, query_key, current_rev)
          Telemetry.durability_skip(query_name, key, entry.durability, current_rev)
          :valid
        else
          # Case 4: walk dependencies.
          walk_dependencies(db, query_key, entry, current_rev, ensure_fn)
        end
    end
  end

  defp walk_dependencies(db, query_key, entry, current_rev, ensure_fn) do
    case check_deps(db, entry.dependencies, entry.verified_at, ensure_fn, :high) do
      {:clean, durability} ->
        # Refresh durability, not just verified_at. It is the minimum over
        # transitive inputs and is otherwise only recomputed when an entry
        # EXECUTES — but early cutoff means a dependent is usually
        # validated without executing, so a stale level would persist and
        # then skip a change at a lower one. The walk just read every
        # dependency's entry, so the current minimum is already in hand.
        Memo.update_verified(db, query_key, current_rev, durability)
        :valid

      :stale ->
        :stale
    end
  end

  defp check_deps(_db, [], _verified_at, _ensure_fn, durability), do: {:clean, durability}

  # Entity field dependencies are checked by reading the field's changed_at
  # directly from the entity table. No ensure_fn call needed — entities are
  # updated in place by the query that creates them.
  defp check_deps(
         db,
         [{:entity_field, module, entity_id, field_name} | rest],
         verified_at,
         ensure_fn,
         durability
       ) do
    changed_at = Entity.field_changed_at(db, module, entity_id, field_name)

    if changed_at > verified_at do
      :stale
    else
      # Entities carry no durability of their own, so they neither raise
      # nor lower the minimum.
      check_deps(db, rest, verified_at, ensure_fn, durability)
    end
  rescue
    ArgumentError -> :stale
  end

  defp check_deps(db, [dep | rest], verified_at, ensure_fn, durability) do
    ensure_fn.(db, dep)

    case Memo.get(db, dep) do
      {:ok, %Entry{changed_at: changed_at}} when changed_at > verified_at ->
        :stale

      {:ok, %Entry{durability: dep_durability}} ->
        check_deps(db, rest, verified_at, ensure_fn, min_durability(durability, dep_durability))

      # Dependency removed after ensure_fn — treat as stale.
      :miss ->
        :stale
    end
  end

  # `:low` is absorbing, matching Runtime's propagation.
  defp min_durability(:low, _), do: :low
  defp min_durability(_, :low), do: :low
  defp min_durability(:medium, _), do: :medium
  defp min_durability(_, :medium), do: :medium
  defp min_durability(_, _), do: :high

  # Extracts query_name and key for telemetry from the query_key tuple.
  defp decompose_query_key({:input, input_name, key}), do: {:input, {input_name, key}}
  defp decompose_query_key({query_name, key}), do: {query_name, key}
end
