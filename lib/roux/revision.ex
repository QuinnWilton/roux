defmodule Roux.Revision do
  @moduledoc """
  Global revision counter and per-durability-level change tracking.

  The revision is a monotonically increasing integer representing a version
  of the world. It increments every time any input changes. Durability
  tracking enables skipping validation of subgraphs rooted in high-durability
  inputs (see D6).

  ## Durability levels

  Durability classifies how often an input changes:

  - `:high` — almost never (standard library, language definitions)
  - `:medium` — occasionally (project source files not being edited)
  - `:low` — constantly (the file currently open in the editor)

  During validation, if a query's entire dependency subgraph has minimum
  durability `:high` and `last_changed(rev, :high) < query.verified_at`,
  the query can skip graph traversal entirely.

  ## Concurrency

  All operations are lock-free. `advance/2` uses `:atomics.add_get/3` for
  the global counter and `:atomics.put/3` for durability tracking.
  `last_changed_at_or_below/2` reads multiple atomics slots without
  cross-slot atomicity — the worst case is a spurious validation
  (conservative, not incorrect).
  """

  @type revision :: non_neg_integer()

  @type durability :: :high | :medium | :low

  @type t :: %__MODULE__{
          counter: :atomics.atomics_ref(),
          durability: :atomics.atomics_ref()
        }

  @enforce_keys [:counter, :durability]
  defstruct [:counter, :durability]

  # Durability level to atomics slot mapping.
  @high_slot 1
  @medium_slot 2
  @low_slot 3

  @doc """
  Creates a new revision tracker. Initial revision is 0 (no inputs set yet).
  """
  @spec new() :: t()
  def new do
    counter = :atomics.new(1, signed: false)
    durability = :atomics.new(3, signed: false)
    %__MODULE__{counter: counter, durability: durability}
  end

  @doc """
  Reads the current global revision. Lock-free.
  """
  @spec current(t()) :: revision()
  def current(%__MODULE__{counter: counter}) do
    :atomics.get(counter, 1)
  end

  @doc """
  Increments the global revision counter and records which durability level
  changed. Returns the new revision number.

  Called when an input is set or modified.
  """
  @spec advance(t(), durability()) :: revision()
  def advance(%__MODULE__{counter: counter, durability: durability}, level)
      when level in [:high, :medium, :low] do
    new_revision = :atomics.add_get(counter, 1, 1)
    :atomics.put(durability, slot(level), new_revision)
    new_revision
  end

  @doc """
  Returns the revision at which the given durability level last had an input
  change. Returns 0 if no input at that level has ever changed.

  Used during validation to skip subgraphs.
  """
  @spec last_changed(t(), durability()) :: revision()
  def last_changed(%__MODULE__{durability: durability}, level)
      when level in [:high, :medium, :low] do
    :atomics.get(durability, slot(level))
  end

  @doc """
  Returns the maximum revision across all durability levels at or below the
  given level. Used for the durability optimization during validation.

  - `:low` includes `:low` + `:medium` + `:high` changes.
  - `:medium` includes `:medium` + `:high` changes.
  - `:high` includes only `:high` changes.
  """
  @spec last_changed_at_or_below(t(), durability()) :: revision()
  def last_changed_at_or_below(%__MODULE__{durability: dur}, :high) do
    :atomics.get(dur, @high_slot)
  end

  def last_changed_at_or_below(%__MODULE__{durability: dur}, :medium) do
    max(
      :atomics.get(dur, @high_slot),
      :atomics.get(dur, @medium_slot)
    )
  end

  def last_changed_at_or_below(%__MODULE__{durability: dur}, :low) do
    high = :atomics.get(dur, @high_slot)
    medium = :atomics.get(dur, @medium_slot)
    low = :atomics.get(dur, @low_slot)
    max(high, max(medium, low))
  end

  @doc """
  Captures the current state of all atomics for manifest persistence.

  Returns a plain map that can be serialized with `:erlang.term_to_binary/1`.
  """
  @spec snapshot(t()) :: %{
          counter: revision(),
          high: revision(),
          medium: revision(),
          low: revision()
        }
  def snapshot(%__MODULE__{counter: counter, durability: durability}) do
    %{
      counter: :atomics.get(counter, 1),
      high: :atomics.get(durability, @high_slot),
      medium: :atomics.get(durability, @medium_slot),
      low: :atomics.get(durability, @low_slot)
    }
  end

  @doc """
  Restores atomics state from a snapshot produced by `snapshot/1`.

  Used during manifest loading to resume the revision timeline across
  VM restarts.
  """
  @spec restore(t(), %{counter: revision(), high: revision(), medium: revision(), low: revision()}) ::
          :ok
  def restore(%__MODULE__{counter: counter, durability: durability}, state) do
    :atomics.put(counter, 1, state.counter)
    :atomics.put(durability, @high_slot, state.high)
    :atomics.put(durability, @medium_slot, state.medium)
    :atomics.put(durability, @low_slot, state.low)
    :ok
  end

  defp slot(:high), do: @high_slot
  defp slot(:medium), do: @medium_slot
  defp slot(:low), do: @low_slot
end
