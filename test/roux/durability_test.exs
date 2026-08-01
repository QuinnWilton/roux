defmodule Roux.DurabilityTest do
  @moduledoc """
  Per-key durability, and the two ways it is silently unsound without care.

  Durability lets a consumer say "this input changes constantly, those do
  not", so validation can skip the dependency walk for anything that
  cannot be affected. Salsa marks the file being edited LOW for exactly
  this. Both failures below produce STALE VALUES with no error, so each
  gets a test that checks the value, not the bookkeeping.
  """

  use ExUnit.Case, async: true

  alias Roux.{Database, Input, Memo, Runtime}

  setup do
    db = Database.new()

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    %{db: db}
  end

  defp register_input(db, name, opts \\ []) do
    Input.register(db, Input.define(name, opts))
  end

  describe "per-key durability" do
    test "a key can override the input definition's level", %{db: db} do
      register_input(db, :source, durability: :medium)
      Input.set(db, :source, "hot", "a", durability: :low)
      Input.set(db, :source, "cold", "b")

      assert {:ok, %{durability: :low}} = Memo.get(db, {:input, :source, "hot"})
      assert {:ok, %{durability: :medium}} = Memo.get(db, {:input, :source, "cold"})
    end

    test "a reader takes the level of the key it actually read", %{db: db} do
      register_input(db, :source, durability: :medium)
      Input.set(db, :source, "hot", "a", durability: :low)
      Input.set(db, :source, "cold", "b")

      reader = fn db, key -> Runtime.input(db, :source, key) end

      Runtime.execute(db, :read, "hot", reader)
      Runtime.execute(db, :read, "cold", reader)

      assert {:ok, %{durability: :low}} = Memo.get(db, {:read, "hot"})
      assert {:ok, %{durability: :medium}} = Memo.get(db, {:read, "cold"})
    end
  end

  describe "soundness" do
    test "lowering a key's durability still invalidates its readers", %{db: db} do
      # A reader recorded at :medium checks only :medium and above. If
      # lowering the key advanced solely the low slot, that reader would
      # skip validation forever and serve the old value.
      register_input(db, :source, durability: :medium)
      Input.set(db, :source, "k", "v1")

      reader = fn db, key -> Runtime.input(db, :source, key) end
      assert Runtime.execute(db, :read, "k", reader) == "v1"

      Input.set(db, :source, "k", "v2", durability: :low)

      assert Runtime.execute(db, :read, "k", reader) == "v2",
             "a reader recorded at the old durability served a stale value"
    end

    test "a dependent that early-cut still sees a later low-durability change", %{db: db} do
      # THE subtle one. Durability is the min over transitive inputs,
      # computed when an entry EXECUTES. Early cutoff means a dependent is
      # usually validated WITHOUT executing — so unless validation
      # refreshes the level, the dependent keeps `:medium` forever and
      # then skips a `:low` change, silently.
      register_input(db, :source, durability: :medium)
      Input.set(db, :source, "leaf", "1")

      # middle cuts off: it reports only whether the leaf is non-empty.
      middle = fn db, key -> Runtime.input(db, :source, key) != "" end
      top = fn db, key -> {:top, Runtime.execute(db, :middle, key, middle)} end

      assert Runtime.execute(db, :top, "leaf", top) == {:top, true}

      # Switch the key to :low, then make a change that MUST propagate.
      Input.set(db, :source, "leaf", "2", durability: :low)
      assert Runtime.execute(db, :top, "leaf", top) == {:top, true}

      # This edit early-cuts at `middle` (still non-empty), so `top` is
      # validated without executing and never re-records its durability.
      Input.set(db, :source, "leaf", "3", durability: :low)
      assert Runtime.execute(db, :top, "leaf", top) == {:top, true}

      # Now a change that does reach the top. If durability went stale,
      # `top` skips validation and answers `true`.
      Input.set(db, :source, "leaf", "", durability: :low)

      assert Runtime.execute(db, :top, "leaf", top) == {:top, false},
             "a dependent kept a stale durability through early cutoff and " <>
               "skipped a low-durability change"
    end

    test "validation refreshes an entry's durability", %{db: db} do
      register_input(db, :source, durability: :medium)
      Input.set(db, :source, "k", "v1")

      reader = fn db, key -> Runtime.input(db, :source, key) end
      Runtime.execute(db, :read, "k", reader)
      assert {:ok, %{durability: :medium}} = Memo.get(db, {:read, "k"})

      # Lower the key, then force a validation walk of the reader.
      Input.set(db, :source, "k", "v2", durability: :low)
      Runtime.execute(db, :read, "k", reader)

      assert {:ok, %{durability: :low}} = Memo.get(db, {:read, "k"}),
             "the reader kept the level it was first computed with"
    end
  end
end
