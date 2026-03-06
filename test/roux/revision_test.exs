defmodule Roux.RevisionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.Revision

  setup do
    %{rev: Revision.new()}
  end

  describe "new/0" do
    test "initial revision is 0", %{rev: rev} do
      assert Revision.current(rev) == 0
    end
  end

  describe "current/1" do
    test "returns 0 on fresh tracker", %{rev: rev} do
      assert Revision.current(rev) == 0
    end

    test "reflects advances", %{rev: rev} do
      Revision.advance(rev, :low)
      assert Revision.current(rev) == 1

      Revision.advance(rev, :medium)
      assert Revision.current(rev) == 2
    end
  end

  describe "advance/2" do
    test "increments and returns consecutive values", %{rev: rev} do
      assert Revision.advance(rev, :low) == 1
      assert Revision.advance(rev, :medium) == 2
      assert Revision.advance(rev, :high) == 3
    end

    test "returns the new revision number", %{rev: rev} do
      new_rev = Revision.advance(rev, :low)
      assert new_rev == Revision.current(rev)
    end

    test "works with all durability levels", %{rev: rev} do
      for level <- [:high, :medium, :low] do
        result = Revision.advance(rev, level)
        assert is_integer(result) and result > 0
      end
    end
  end

  describe "last_changed/2" do
    test "returns 0 for levels that haven't changed", %{rev: rev} do
      assert Revision.last_changed(rev, :high) == 0
      assert Revision.last_changed(rev, :medium) == 0
      assert Revision.last_changed(rev, :low) == 0
    end

    test "returns correct revision after advance", %{rev: rev} do
      r1 = Revision.advance(rev, :low)
      assert Revision.last_changed(rev, :low) == r1
      assert Revision.last_changed(rev, :medium) == 0
      assert Revision.last_changed(rev, :high) == 0
    end

    test "tracks each level independently", %{rev: rev} do
      r1 = Revision.advance(rev, :high)
      r2 = Revision.advance(rev, :medium)
      r3 = Revision.advance(rev, :low)

      assert Revision.last_changed(rev, :high) == r1
      assert Revision.last_changed(rev, :medium) == r2
      assert Revision.last_changed(rev, :low) == r3
    end

    test "updates to latest when same level advances multiple times", %{rev: rev} do
      Revision.advance(rev, :low)
      r2 = Revision.advance(rev, :low)

      assert Revision.last_changed(rev, :low) == r2
    end
  end

  describe "last_changed_at_or_above/2" do
    test "returns 0 on fresh tracker for all levels", %{rev: rev} do
      assert Revision.last_changed_at_or_above(rev, :high) == 0
      assert Revision.last_changed_at_or_above(rev, :medium) == 0
      assert Revision.last_changed_at_or_above(rev, :low) == 0
    end

    test ":high includes only :high changes", %{rev: rev} do
      r1 = Revision.advance(rev, :high)
      _r2 = Revision.advance(rev, :medium)
      _r3 = Revision.advance(rev, :low)

      assert Revision.last_changed_at_or_above(rev, :high) == r1
    end

    test ":medium includes :medium + :high changes", %{rev: rev} do
      _r1 = Revision.advance(rev, :high)
      r2 = Revision.advance(rev, :medium)
      _r3 = Revision.advance(rev, :low)

      # :medium should be max(:high, :medium) = max(1, 2) = 2
      assert Revision.last_changed_at_or_above(rev, :medium) == r2
    end

    test ":low includes :low + :medium + :high changes", %{rev: rev} do
      _r1 = Revision.advance(rev, :high)
      _r2 = Revision.advance(rev, :medium)
      r3 = Revision.advance(rev, :low)

      # :low should be max(:high, :medium, :low) = max(1, 2, 3) = 3
      assert Revision.last_changed_at_or_above(rev, :low) == r3
    end

    test "returns max across relevant levels regardless of advance order", %{rev: rev} do
      # Advance low first, then high — high gets a higher revision number.
      _r1 = Revision.advance(rev, :low)
      r2 = Revision.advance(rev, :high)

      # :medium includes :medium + :high, and :high (r2) is the max.
      assert Revision.last_changed_at_or_above(rev, :medium) == r2

      # :low includes all three, and :high (r2) is still the max.
      assert Revision.last_changed_at_or_above(rev, :low) == r2
    end
  end

  # -- Property tests --

  describe "properties" do
    property "revision is strictly monotonically increasing across advances" do
      check all(
              levels <- list_of(member_of([:high, :medium, :low]), min_length: 1, max_length: 100)
            ) do
        rev = Revision.new()

        revisions =
          Enum.map(levels, fn level ->
            Revision.advance(rev, level)
          end)

        # Each revision is strictly greater than the previous.
        revisions
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [a, b] -> assert b > a end)
      end
    end

    property "last_changed(level) is always <= current()" do
      check all(
              levels <- list_of(member_of([:high, :medium, :low]), min_length: 0, max_length: 50),
              check_level <- member_of([:high, :medium, :low])
            ) do
        rev = Revision.new()
        Enum.each(levels, &Revision.advance(rev, &1))

        assert Revision.last_changed(rev, check_level) <= Revision.current(rev)
      end
    end

    property "at_or_below ordering: low >= medium >= high" do
      check all(
              levels <- list_of(member_of([:high, :medium, :low]), min_length: 0, max_length: 50)
            ) do
        rev = Revision.new()
        Enum.each(levels, &Revision.advance(rev, &1))

        low = Revision.last_changed_at_or_above(rev, :low)
        medium = Revision.last_changed_at_or_above(rev, :medium)
        high = Revision.last_changed_at_or_above(rev, :high)

        assert low >= medium
        assert medium >= high
      end
    end
  end
end
