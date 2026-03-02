defmodule Roux.CycleTest do
  use ExUnit.Case, async: true

  alias Roux.Cycle
  alias Roux.Cycle.Error
  alias Roux.Runtime.Context

  # Context with a specific query stack. The db field is unused by Cycle
  # but required by the struct, so we use a placeholder.
  defp context(stack) do
    %Context{db: :test_db, query_stack: stack}
  end

  # -- check/2 (non-raising) --

  describe "check/2" do
    test "returns :ok on empty stack" do
      assert Cycle.check(context([]), {:parse, "file.ex"}) == :ok
    end

    test "returns :ok when query is not on stack" do
      stack = [{:parse, "a.ex"}, {:compile, "b.ex"}, {:typecheck, "c.ex"}]
      assert Cycle.check(context(stack), {:resolve, "d.ex"}) == :ok
    end

    test "detects direct self-cycle" do
      stack = [{:parse, "a.ex"}]
      assert {:cycle, cycle} = Cycle.check(context(stack), {:parse, "a.ex"})
      assert cycle == [{:parse, "a.ex"}, {:parse, "a.ex"}]
    end

    test "detects indirect cycle" do
      stack = [{:typecheck, "a.ex"}, {:resolve, "b.ex"}]
      assert {:cycle, cycle} = Cycle.check(context(stack), {:typecheck, "a.ex"})
      assert cycle == [{:typecheck, "a.ex"}, {:resolve, "b.ex"}, {:typecheck, "a.ex"}]
    end

    test "detects cycle in middle of stack" do
      stack = [{:parse, "d.ex"}, {:typecheck, "a.ex"}, {:resolve, "b.ex"}]
      assert {:cycle, cycle} = Cycle.check(context(stack), {:typecheck, "a.ex"})
      # Cycle starts from the first occurrence, not from the beginning of the stack.
      assert cycle == [{:typecheck, "a.ex"}, {:resolve, "b.ex"}, {:typecheck, "a.ex"}]
    end

    test "detects long indirect cycle" do
      stack = [{:a, 1}, {:b, 2}, {:c, 3}, {:d, 4}]
      assert {:cycle, cycle} = Cycle.check(context(stack), {:a, 1})
      assert cycle == [{:a, 1}, {:b, 2}, {:c, 3}, {:d, 4}, {:a, 1}]
    end

    test "handles input query keys" do
      stack = [{:parse, "a.ex"}, {:input, :source, "b.ex"}]
      assert Cycle.check(context(stack), {:compile, "c.ex"}) == :ok
      assert {:cycle, _} = Cycle.check(context(stack), {:parse, "a.ex"})
    end
  end

  # -- check!/2 (raising) --

  describe "check!/2" do
    test "returns :ok when no cycle" do
      assert Cycle.check!(context([]), {:parse, "a.ex"}) == :ok
    end

    test "raises Roux.Cycle.Error on direct cycle" do
      stack = [{:parse, "a.ex"}]

      error =
        assert_raise Error, fn ->
          Cycle.check!(context(stack), {:parse, "a.ex"})
        end

      assert error.cycle == [{:parse, "a.ex"}, {:parse, "a.ex"}]
    end

    test "raises Roux.Cycle.Error on indirect cycle" do
      stack = [{:typecheck, "a.ex"}, {:resolve, "b.ex"}]

      error =
        assert_raise Error, fn ->
          Cycle.check!(context(stack), {:typecheck, "a.ex"})
        end

      assert error.cycle == [
               {:typecheck, "a.ex"},
               {:resolve, "b.ex"},
               {:typecheck, "a.ex"}
             ]
    end
  end

  # -- Error message --

  describe "error message" do
    test "includes the full cycle path with arrows" do
      error = %Error{cycle: [{:typecheck, "a.ex"}, {:resolve, "b.ex"}, {:typecheck, "a.ex"}]}

      message = Exception.message(error)
      assert message =~ "cycle detected in query graph:"
      assert message =~ "{:typecheck, \"a.ex\"} → {:resolve, \"b.ex\"} → {:typecheck, \"a.ex\"}"
    end

    test "handles direct cycle message" do
      error = %Error{cycle: [{:parse, "a.ex"}, {:parse, "a.ex"}]}

      message = Exception.message(error)
      assert message =~ "{:parse, \"a.ex\"} → {:parse, \"a.ex\"}"
    end
  end
end
