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

  All operations are lock-free. A revision becomes current only after its
  change is visible: `advance/3` makes the change with the revision it is
  about to publish, raises the durability slot, and only then publishes the
  revision with a compare-and-swap. A reader that captured a revision and
  then saw the old value therefore captured one older than the change, and
  its result validates as stale. Publishing first and writing after would
  let a reader record the old value as current at the new revision. A
  concurrent advance that publishes first makes the write run again with
  the next revision.

  `last_changed_at_or_above/2` reads multiple atomics slots without
  cross-slot atomicity, and a slot can briefly lead the counter — the worst
  case is a spurious validation (conservative, not incorrect).
  """

  @type revision :: non_neg_integer()

  @type durability :: :high | :medium | :low

  @type t :: %__MODULE__{
          counter: :atomics.atomics_ref(),
          durability: :atomics.atomics_ref(),
          untracked: :atomics.atomics_ref() | nil
        }

  @enforce_keys [:counter, :durability]
  defstruct [:counter, :durability, :untracked]

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

    %__MODULE__{
      counter: counter,
      durability: durability,
      untracked: :atomics.new(1, signed: false)
    }
  end

  @doc """
  Reads the current global revision. Lock-free.
  """
  @spec current(t()) :: revision()
  def current(%__MODULE__{counter: counter}) do
    :atomics.get(counter, 1)
  end

  @doc """
  Publishes the next revision, recording that `level` changed at it, and
  returns that revision.

  `write` receives the revision about to be published and makes the change
  visible before it is: a change made after its revision is current could be
  missed by a reader at that revision. When a concurrent advance publishes
  first, `write` runs again with the next revision, so it must leave the
  change stamped with the last revision it receives. A change already made
  before the call (a deletion, say) needs no `write`.
  """
  @spec advance(t(), durability(), (revision() -> term())) :: revision()
  def advance(%__MODULE__{} = revision, level, write \\ &ignore/1)
      when level in [:high, :medium, :low] and is_function(write, 1) do
    note_untracked(revision)
    advance_tracked(revision, level, write)
  end

  @doc false
  @spec advance_tracked(t(), durability(), (revision() -> term())) :: revision()
  def advance_tracked(
        %__MODULE__{counter: counter, durability: durability} = revision,
        level,
        write \\ &ignore/1
      )
      when level in [:high, :medium, :low] and is_function(write, 1) do
    current = :atomics.get(counter, 1)
    next = current + 1
    write.(next)
    # Before the counter: a validation at `next` must not skip on a stale slot.
    raise_slot(durability, slot(level), next)

    case :atomics.compare_exchange(counter, 1, current, next) do
      :ok -> next
      _published -> advance_tracked(revision, level, write)
    end
  end

  defp ignore(_revision), do: :ok

  defp raise_slot(durability, slot, revision) do
    case :atomics.get(durability, slot) do
      seen when seen >= revision ->
        :ok

      seen ->
        case :atomics.compare_exchange(durability, slot, seen, revision) do
          :ok -> :ok
          _moved -> raise_slot(durability, slot, revision)
        end
    end
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
  Returns the maximum revision across all durability levels at or above the
  given level. Used for the durability optimization during validation.

  Higher durability means more stable (changes less often):

  - `:low` includes `:low` + `:medium` + `:high` changes (all levels).
  - `:medium` includes `:medium` + `:high` changes.
  - `:high` includes only `:high` changes.
  """
  @spec last_changed_at_or_above(t(), durability()) :: revision()
  def last_changed_at_or_above(%__MODULE__{durability: dur}, :high) do
    :atomics.get(dur, @high_slot)
  end

  def last_changed_at_or_above(%__MODULE__{durability: dur}, :medium) do
    max(
      :atomics.get(dur, @high_slot),
      :atomics.get(dur, @medium_slot)
    )
  end

  def last_changed_at_or_above(%__MODULE__{durability: dur}, :low) do
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
  def restore(%__MODULE__{counter: counter, durability: durability} = revision, state) do
    note_untracked(revision)
    :atomics.put(counter, 1, state.counter)
    :atomics.put(durability, @high_slot, state.high)
    :atomics.put(durability, @medium_slot, state.medium)
    :atomics.put(durability, @low_slot, state.low)
    :ok
  end

  @doc false
  @spec untracked(t()) :: non_neg_integer()
  def untracked(%__MODULE__{untracked: nil}), do: 0
  def untracked(%__MODULE__{untracked: clock}), do: :atomics.get(clock, 1)

  defp note_untracked(%__MODULE__{untracked: nil}), do: :ok
  defp note_untracked(%__MODULE__{untracked: clock}), do: :atomics.add(clock, 1, 1)

  defp slot(:high), do: @high_slot
  defp slot(:medium), do: @medium_slot
  defp slot(:low), do: @low_slot
end
