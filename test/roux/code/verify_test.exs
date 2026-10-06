defmodule Roux.Code.VerifyTest.Probe do
  @moduledoc false

  def run(n), do: Enum.each(1..n//1, &step/1)
  def other, do: :other

  defp step(x), do: x
end

defmodule Roux.Code.VerifyTest do
  @moduledoc """
  Call counting for closure tests (`Roux.Code.Verify`): a session turned
  on once, each run read apart, function by function, and nothing else
  the VM traces disturbed.

  Counts are VM-wide, but each test counts a module only it calls, and
  sessions take turns, so the tests run beside the rest of the suite.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.Code.Verify
  alias Roux.Code.VerifyTest.Probe

  @run {Probe, :run, 1}
  @step {Probe, :step, 1}
  @other {Probe, :other, 0}

  describe "executed/2" do
    test "names the modules a computation called into, sorted" do
      fresh = compile!("def go, do: :ok")

      {result, ran} =
        Verify.executed(fn -> fresh.go() && Probe.run(1) end, modules: [fresh, Probe])

      assert result == :ok
      assert ran == Enum.sort([fresh, Probe])
    end

    test "names none for a computation that calls into no watched module" do
      assert Verify.executed(fn -> :done end, modules: [Probe]) == {:done, []}
    end

    test "does not count itself, which runs after the computation to read the counts" do
      assert Verify.executed(fn -> :done end, modules: [Verify, Probe]) == {:done, []}
    end
  end

  describe "counting/2 and calls/2" do
    test "count each function a run calls, private ones too, with how often" do
      Verify.counting(
        fn session ->
          assert Verify.calls(session, fn -> Probe.run(3) end) == {:ok, %{@run => 1, @step => 3}}
        end,
        modules: [Probe]
      )
    end

    test "read each run as the counts it moved" do
      Verify.counting(
        fn session ->
          assert {:ok, %{@step => 2}} = Verify.calls(session, fn -> Probe.run(2) end)
          # Between runs: counted, and no part of the next.
          Probe.run(5)
          assert {:other, calls} = Verify.calls(session, &Probe.other/0)
          assert calls == %{@other => 1}
        end,
        modules: [Probe]
      )
    end

    property "a function called n times reads n, and one not called is absent" do
      Verify.counting(
        fn session ->
          check all(n <- integer(0..20)) do
            {:ok, calls} = Verify.calls(session, fn -> Probe.run(n) end)
            assert Map.get(calls, @step) == if(n > 0, do: n)
            assert Map.fetch!(calls, @run) == 1
          end
        end,
        modules: [Probe]
      )
    end

    test "leave tracing set elsewhere in the VM alone" do
      # A call trace another test set, on a module the session does not
      # watch: resetting every counter in the VM cleared it.
      traced = compile!("def f(x), do: x")
      mfa = {traced, :f, 1}
      1 = :erlang.trace_pattern(mfa, true, [])
      on_exit(fn -> :erlang.trace_pattern(mfa, false, []) end)

      Verify.counting(
        fn session ->
          assert {:ok, %{@run => 1}} = Verify.calls(session, fn -> Probe.run(1) end)
          assert {:ok, %{@run => 1}} = Verify.calls(session, fn -> Probe.run(1) end)
        end,
        modules: [Probe]
      )

      assert :erlang.trace_info(mfa, :traced) == {:traced, :global}
    end

    test "turn counting off when the session ends, or raises" do
      Verify.counting(fn _session -> :ok end, modules: [Probe])
      assert :erlang.trace_info(@run, :call_count) == {:call_count, false}

      assert_raise RuntimeError, fn ->
        Verify.counting(fn _session -> raise "boom" end, modules: [Probe])
      end

      assert :erlang.trace_info(@run, :call_count) == {:call_count, false}
    end

    test "load the modules to watch, and leave out those that do not exist" do
      fresh = compile!("def go, do: :ok")
      :code.purge(fresh)
      :code.delete(fresh)
      refute :erlang.module_loaded(fresh)

      missing = Module.concat(__MODULE__, "Missing#{System.unique_integer([:positive])}")

      Verify.counting(
        fn session ->
          assert session.modules == [Probe]
        end,
        modules: [Probe, missing]
      )
    end

    test "take turns with a session another process opens" do
      parent = self()

      Verify.counting(
        fn _session ->
          spawn_link(fn ->
            Verify.counting(fn _ -> send(parent, :second) end, modules: [Probe])
          end)

          refute_receive :second, 200
        end,
        modules: [Probe]
      )

      assert_receive :second, 10_000
    end
  end

  describe "ignore/2" do
    # The trap: a function not counted reads `false`, and every atom
    # compares above every number, so a bare `n > 0` takes it for called.
    test "reads a function no longer counted as not called" do
      Verify.counting(
        fn session ->
          assert {:ok, %{@step => 1}} = Verify.calls(session, fn -> Probe.run(1) end)
          :ok = Verify.ignore(session, [@step])

          {:call_count, counter} = :erlang.trace_info(@step, :call_count)
          assert counter == false
          # What a bare `n > 0` makes of it.
          assert counter > 0

          assert Verify.calls(session, fn -> Probe.run(4) end) == {:ok, %{@run => 1}}
        end,
        modules: [Probe]
      )
    end

    test "keeps counting module_info/0, by which a session sees a module is counted" do
      Verify.counting(
        fn session ->
          :ok = Verify.ignore(session, [{Probe, :module_info, 0}, @other])
          assert {:other, calls} = Verify.calls(session, &Probe.other/0)
          assert calls == %{}
        end,
        modules: [Probe]
      )
    end
  end

  describe "a module no longer counted" do
    test "raises when it was loaded again during the session" do
      {fresh, binary} = compile_binary!("def go, do: :ok")

      Verify.counting(
        fn session ->
          {:module, ^fresh} = :code.load_binary(fresh, ~c"nofile", binary)

          error = assert_raise Verify.UncountedError, fn -> Verify.calls(session, &fresh.go/0) end
          assert error.modules == [fresh]
          assert Exception.message(error) =~ inspect(fresh)
        end,
        modules: [fresh, Probe]
      )
    end

    test "raises when it was unloaded during the session" do
      fresh = compile!("def go, do: :ok")

      Verify.counting(
        fn session ->
          :code.purge(fresh)
          :code.delete(fresh)
          :code.purge(fresh)

          assert_raise Verify.UncountedError, fn -> Verify.calls(session, fn -> :ok end) end
        end,
        modules: [fresh]
      )
    end
  end

  defp compile!(body), do: body |> compile_binary!() |> elem(0)

  defp compile_binary!(body) do
    module = Module.concat(__MODULE__, "Fresh#{System.unique_integer([:positive])}")

    [{^module, binary}] =
      Code.compile_string("defmodule #{inspect(module)} do\n#{body}\nend")

    on_exit(fn -> :code.purge(module) && :code.delete(module) && :code.purge(module) end)
    {module, binary}
  end
end
