defmodule Roux.Code.EscriptTest do
  @moduledoc """
  Code in an escript: `Roux.Code` reads it out of the escript's archive,
  Elixir embedded beside it. Each escript here packs a few probe modules,
  roux's own beams (its main is `Roux.Test.EscriptProbe`) and Elixir's
  standard library, as `mix escript.build` embeds it, and runs in a VM of
  its own.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp name(prefix),
    do: Module.concat([__MODULE__, "#{prefix}#{System.unique_integer([:positive])}"])

  defp names, do: %{a: name("A"), b: name("B"), c: name("C")}

  # Three probe modules calling down a chain: A imports B, and B holds
  # C as a captured function.
  defp source(%{a: a, b: b, c: c}, leaf_body) do
    """
    defmodule #{inspect(a)} do
      def run(x), do: #{inspect(b)}.step(x)
    end

    defmodule #{inspect(b)} do
      def step(x), do: Enum.map(x, &#{inspect(c)}.leaf/1)
    end

    defmodule #{inspect(c)} do
      def leaf(x), do: #{leaf_body}
    end
    """
  end

  defp compile(source) do
    for {module, beam} <- Code.compile_string(source, "probe.ex") do
      :code.purge(module)
      :code.delete(module)
      {module, beam}
    end
  end

  defp ebin_files(app, dir) do
    for path <- Path.wildcard(Path.join(dir, "*")) do
      {String.to_charlist("#{app}/ebin/#{Path.basename(path)}"), File.read!(path)}
    end
  end

  # An escript at `path` packing the probes, roux and Elixir, its mtime
  # set `age` seconds back (a stamp that old is trusted).
  defp escript!(path, source, age) do
    probes =
      for {module, beam} <- compile(source),
          do: {String.to_charlist("probe/ebin/#{module}.beam"), beam}

    files =
      probes ++
        ebin_files(:roux, Path.join(:code.lib_dir(:roux), "ebin")) ++
        ebin_files(:elixir, Path.join(:code.lib_dir(:elixir), "ebin"))

    :ok =
      :escript.create(String.to_charlist(path), [
        :shebang,
        {:emu_args, ~c"-escript main Elixir.Roux.Test.EscriptProbe"},
        {:archive, files, [{:uncompress, :all}]}
      ])

    File.chmod!(path, 0o755)
    File.touch!(path, System.os_time(:second) - age)
    path
  end

  defp run!(escript, store, roots) do
    bin = Path.join([:code.root_dir(), "bin", "escript"])
    args = [escript, store | Enum.map(roots, &Atom.to_string/1)]
    {out, 0} = System.cmd(bin, args, stderr_to_stdout: true)
    out |> String.trim() |> Base.decode64!() |> :erlang.binary_to_term()
  end

  test "reads an escript's modules, keeps its digest over one stat, and sees a change",
       %{tmp_dir: tmp} do
    %{a: a, b: b, c: c} = names = names()
    escript = escript!(Path.join(tmp, "tool"), source(names, "x + 1"), 120)
    store = Path.join(tmp, "store")

    first = run!(escript, store, [a])

    # Elixir is embedded: its library directory is inside the archive.
    assert String.starts_with?(first.elixir_lib_dir, escript <> "/")

    # The probes are code, read out of the archive; Elixir's own modules
    # (Enum) are the runtime's.
    assert {:ok, closure} = first.closure
    assert Enum.map(closure, &elem(&1, 0)) == Enum.sort([a, b, c])

    for {_module, location} <- closure do
      assert String.starts_with?(location, escript <> "/probe/ebin/")
    end

    assert {:ok, digest} = first.digest
    assert first.reads > 0

    # One trace, over one stamp: the escript's.
    [trace] = Path.wildcard(Path.join([store, "traces", "*", "*"]))
    {:ok, {_name, deps, ^digest}} = Roux.Blob.decode(File.read!(trace))
    assert [{{:file, ^escript}, {_size, _mtime, _inode, _ctime}}] = deps

    # A fresh VM verifies that one stat and reads no beam.
    second = run!(escript, store, [a])
    assert second.digest == {:ok, digest}
    assert second.reads == 0

    # A module in the archive changed: the escript's stamp moved, and so
    # does the digest.
    escript!(escript, source(names, "x + 2"), 60)
    third = run!(escript, store, [a])
    assert {:ok, moved} = third.digest
    assert moved != digest
    assert third.reads > 0
  end
end
