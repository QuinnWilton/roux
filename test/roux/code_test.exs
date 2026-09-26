defmodule Roux.CodeTest do
  @moduledoc """
  A code version names the code a computation runs (`Roux.Code`): the
  modules its roots reach, each by a digest of what it does rather
  than of where it was built.
  """

  use ExUnit.Case, async: true

  alias Roux.Code, as: RouxCode
  alias Roux.Code.Verify

  # The trees live outside the working directory: Elixir names a source
  # file in the line table relative to the working directory when it can,
  # and a real build's working directory is its own root.
  setup do
    tmp = Path.join(System.tmp_dir!(), "roux-code-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp_dir: tmp}
  end

  # Builds `source` as if a project at `root` had compiled it: the source
  # under `root/lib`, the beams under `root/_build/test/lib/probe/ebin`.
  # The modules are unloaded again, so the code server finds them on
  # disk and a second build of a name in this test is no redefinition.
  defp build(root, source) do
    file = Path.join([root, "lib", "probe.ex"])
    ebin = Path.join([root, "_build", "test", "lib", "probe", "ebin"])
    File.mkdir_p!(ebin)

    for {module, beam} <- Code.compile_string(source, file) do
      :code.purge(module)
      :code.delete(module)
      path = Path.join(ebin, "#{module}.beam")
      File.write!(path, beam)
      {module, path}
    end
    |> Map.new()
  end

  defp name(prefix),
    do: Module.concat([__MODULE__, "#{prefix}#{System.unique_integer([:positive])}"])

  defp probe(module, opts) do
    returns = Keyword.get(opts, :returns, ":ok")
    doc = Keyword.get(opts, :doc, "A probe.")

    """
    defmodule #{inspect(module)} do
      @moduledoc "#{doc}"
      @compile :debug_info
      @dir __DIR__
      @spec run() :: term()
      def run, do: {@dir, #{returns}, fn -> __ENV__.file end}
    end
    """
  end

  defp digest!(beam, opts \\ []) do
    {:ok, digest} = RouxCode.beam_digest(beam, opts)
    digest
  end

  describe "beam_digest/2" do
    test "one source built in two trees digests the same, with or without debug info",
         %{tmp_dir: tmp} do
      mod = name("Probe")
      %{^mod => a} = build(Path.join(tmp, "worktree-a"), probe(mod, []))
      %{^mod => b} = build(Path.join(tmp, "elsewhere/worktree-b"), probe(mod, []))

      # The bytes differ: the literals, the compile info and the debug
      # info all carry the tree's path.
      assert File.read!(a) != File.read!(b)

      assert digest!(a) == digest!(b)
      assert digest!(a, debug_info: true) == digest!(b, debug_info: true)

      # A binary is digested the same, given the root its path would give.
      assert digest!(File.read!(a), root: RouxCode.build_root(a)) == digest!(a)
    end

    test "a change to the code moves the digest", %{tmp_dir: tmp} do
      mod = name("Probe")
      %{^mod => a} = build(Path.join(tmp, "a"), probe(mod, returns: ":ok"))
      %{^mod => b} = build(Path.join(tmp, "b"), probe(mod, returns: "{:error, :changed}"))

      assert digest!(a) != digest!(b)
      assert digest!(a, debug_info: true) != digest!(b, debug_info: true)
    end

    test "prose that moves no line leaves the digest alone", %{tmp_dir: tmp} do
      mod = name("Probe")
      %{^mod => a} = build(Path.join(tmp, "a"), probe(mod, doc: "A probe."))
      %{^mod => b} = build(Path.join(tmp, "b"), probe(mod, doc: "The same probe, again."))

      assert digest!(a) == digest!(b)
    end

    test "a moved line moves the digest", %{tmp_dir: tmp} do
      mod = name("Probe")
      %{^mod => a} = build(Path.join(tmp, "a"), probe(mod, []))
      %{^mod => b} = build(Path.join(tmp, "b"), "\n# A comment above.\n" <> probe(mod, []))

      assert digest!(a) != digest!(b)
    end

    test "debug info counts only when asked for", %{tmp_dir: tmp} do
      mod = name("Probe")
      source = probe(mod, [])
      %{^mod => a} = build(Path.join(tmp, "a"), source)

      %{^mod => b} =
        build(
          Path.join(tmp, "b"),
          String.replace(source, "@spec run() :: term()", "@spec run() :: tuple()")
        )

      assert digest!(a) == digest!(b)
      assert digest!(a, debug_info: true) != digest!(b, debug_info: true)
    end

    test "a path outside the build root is not normalized away", %{tmp_dir: tmp} do
      mod = name("Probe")
      %{^mod => a} = build(Path.join(tmp, "a"), probe(mod, returns: ~s("/srv/one")))
      %{^mod => b} = build(Path.join(tmp, "b"), probe(mod, returns: ~s("/srv/two")))

      assert digest!(a) != digest!(b)
    end

    test "the build root is the directory holding the innermost _build" do
      assert RouxCode.build_root("/w/a/_build/test/lib/x/ebin/X.beam") == "/w/a"
      assert RouxCode.build_root("/w/a/deps/y/_build/dev/lib/y/ebin/Y.beam") == "/w/a/deps/y"
      assert RouxCode.build_root("/usr/lib/erlang/lib/stdlib/ebin/lists.beam") == nil
    end

    test "an unreadable beam is an error, not a digest", %{tmp_dir: tmp} do
      assert {:error, _reason} = RouxCode.beam_digest(Path.join(tmp, "Missing.beam"))

      garbage = Path.join(tmp, "Garbage.beam")
      File.write!(garbage, "not a beam")
      assert {:error, _reason} = RouxCode.beam_digest(garbage)
    end
  end

  describe "canonical_beam/1" do
    test "drops the chunks that move with no change to the code", %{tmp_dir: tmp} do
      mod = name("Probe")
      %{^mod => a} = build(Path.join(tmp, "a"), probe(mod, doc: "A probe."))

      bin = File.read!(a)
      canonical = RouxCode.canonical_beam(bin)
      {:ok, _mod, chunks} = :beam_lib.all_chunks(canonical)
      ids = Enum.map(chunks, &elem(&1, 0))

      refute ~c"Docs" in ids
      refute ~c"ExCk" in ids
      assert ~c"Code" in ids
      assert RouxCode.canonical_beam("not a beam") == "not a beam"
    end
  end

  # Three modules calling down a chain, one beside them, one calling
  # through a module that is not there, all on the code path from disk.
  defp chain!(tmp) do
    [a, b, c, d, missing] = for p <- ~w(A B C D Missing), do: name(p)

    source = """
    defmodule #{inspect(a)} do
      @compile {:no_warn_undefined, #{inspect(missing)}}
      def run(x), do: x |> Enum.map(&#{inspect(b)}.step/1) |> :lists.reverse()
      def later, do: #{inspect(missing)}.go()
    end

    defmodule #{inspect(b)} do
      def step(x), do: #{inspect(c)}.leaf(x)
    end

    defmodule #{inspect(c)} do
      def leaf(x), do: x + 1
    end

    defmodule #{inspect(d)} do
      def alone, do: :alone
    end
    """

    root = Path.join(tmp, "chain")
    paths = build(root, source)
    ebin = paths |> Map.fetch!(a) |> Path.dirname()
    true = :code.add_patha(String.to_charlist(ebin))

    on_exit(fn ->
      :code.del_path(String.to_charlist(ebin))
      for mod <- [a, b, c, d], do: :code.purge(mod) && :code.delete(mod)
    end)

    %{a: a, b: b, c: c, d: d, missing: missing, paths: paths}
  end

  describe "closure/2" do
    test "follows the import table through the project, and stops at the runtime",
         %{tmp_dir: tmp} do
      %{a: a, b: b, c: c, missing: missing, paths: paths} = chain!(tmp)

      assert {:ok, closure} = RouxCode.closure([a])

      assert closure ==
               Enum.sort([
                 {a, paths[a]},
                 {b, paths[b]},
                 {c, paths[c]},
                 {missing, :absent}
               ])
    end

    test "leaves out what it excludes, going on through it unless told not to",
         %{tmp_dir: tmp} do
      %{a: a, b: b, c: c, missing: missing} = chain!(tmp)

      assert {:ok, through} = RouxCode.closure([a], exclude: [b])
      assert Enum.map(through, &elem(&1, 0)) == Enum.sort([a, c, missing])

      assert {:ok, stopped} = RouxCode.closure([a], exclude: &(&1 == b), follow_excluded: false)
      assert Enum.map(stopped, &elem(&1, 0)) == Enum.sort([a, missing])

      assert_raise ArgumentError, fn -> RouxCode.closure([a], exclude: :b) end
    end

    test "a module compiled in memory has no closure" do
      [{mod, _bin}] =
        Code.compile_string("defmodule #{inspect(name("InMemory"))}, do: def(x, do: 1)")

      assert {:error, {:no_beam, ^mod}} = RouxCode.closure([mod])
      assert {:error, {:no_beam, ^mod}} = RouxCode.digest([mod])
    end
  end

  describe "digest/2" do
    test "differs between root sets, and is stable within a VM", %{tmp_dir: tmp} do
      %{a: a, b: b, d: d} = chain!(tmp)

      assert {:ok, whole} = RouxCode.digest([a])
      assert {:ok, lower} = RouxCode.digest([b])
      assert {:ok, beside} = RouxCode.digest([a, d])
      assert Enum.uniq([whole, lower, beside]) == [whole, lower, beside]
      assert {:ok, ^whole} = RouxCode.digest([a])
      assert String.match?(whole, ~r/^[0-9a-f]{64}$/)
    end

    test "moves with an edit to a module the roots reach", %{tmp_dir: tmp} do
      %{a: a, c: c, paths: paths} = chain!(tmp)
      {:ok, before} = RouxCode.digest([a])

      # C rebuilt in place with another body, as a recompile would: built
      # elsewhere (the old beam out of the compiler's sight) and put where
      # the old one was.
      File.rm!(paths[c])

      %{^c => rebuilt} =
        build(Path.join(tmp, "edit"), "defmodule #{inspect(c)}, do: def(leaf(x), do: x + 2)")

      File.cp!(rebuilt, paths[c])

      # Memoized per VM: the old digest until forgotten.
      assert {:ok, ^before} = RouxCode.digest([a])
      :ok = RouxCode.forget()
      assert {:ok, moved} = RouxCode.digest([a])
      assert moved != before
    end
  end

  describe "Verify.executed/2" do
    test "names the modules a computation called into", %{tmp_dir: tmp} do
      %{a: a, b: b, c: c, d: d} = chain!(tmp)

      {result, ran} = Verify.executed(fn -> a.run([1, 2]) end, modules: [a, b, c, d])

      assert result == [3, 2]
      assert ran == Enum.sort([a, b, c])

      {:ok, closure} = RouxCode.closure([a])
      assert ran -- Enum.map(closure, &elem(&1, 0)) == []
    end
  end
end
