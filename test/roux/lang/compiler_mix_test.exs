defmodule Roux.Lang.CompilerMixTest do
  @moduledoc """
  `mix compile` of a project whose language is its own Elixir code,
  `:roux` listed before `:elixir`, each build a Mix of its own: roux is
  on its code path through `ERL_LIBS` (this suite's build), and it runs
  the Elixir and Erlang this suite runs.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # A project of one language, `<ns>.Lang`, compiling `src/*.warm`
  # into modules that keep the text they were compiled from.
  defp project!(dir) do
    ns = "RouxBuild#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "src"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{ns}.MixProject do
      use Mix.Project

      def project do
        [
          app: :roux_build,
          version: "0.1.0",
          compilers: [:roux] ++ Mix.compilers(),
          roux: [languages: [#{ns}.Lang], source_dirs: ["src"]],
          prune_code_paths: false,
          deps: []
        ]
      end
    end
    """)

    File.write!(Path.join(dir, "lib/lang.ex"), """
    defmodule #{ns}.Lang do
      @behaviour Roux.Lang
      use Roux.Query

      @impl Roux.Lang
      def file_extensions, do: [".warm"]

      @impl Roux.Lang
      def compile_query, do: :warm_compile

      @impl Roux.Lang
      def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

      definput :source_text, durability: :low

      defquery :warm_compile, key: path do
        text = String.trim(Roux.Runtime.input(db, :source_text, path))
        name = Module.concat(#{ns}, Macro.camelize(Path.basename(path, ".warm")))

        {:ok,
         quote do
           defmodule unquote(name) do
             Module.register_attribute(__MODULE__, :warm, persist: true)
             @warm unquote(text)
           end
         end}
      end
    end
    """)

    File.write!(Path.join(dir, "src/hello.warm"), "one\n")
    %{dir: dir, ns: ns}
  end

  defp build(%{dir: dir}) do
    elixir_bin = Path.expand("../../bin", :code.lib_dir(:elixir))
    otp_bin = Path.join(:code.root_dir(), "bin")

    System.cmd(Path.join(elixir_bin, "mix"), ["compile"],
      cd: dir,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "dev"},
        {"ERL_LIBS", Path.dirname(:code.lib_dir(:roux))},
        {"PATH", "#{otp_bin}:#{elixir_bin}:#{System.get_env("PATH")}"},
        {"MIX_BUILD_PATH", nil},
        {"MIX_EXS", nil},
        {"MIX_DEPS_PATH", nil},
        {"MIX_LOCKFILE", nil}
      ]
    )
  end

  defp ebin(%{dir: dir}), do: Path.join(dir, "_build/dev/lib/roux_build/ebin")

  # The text the module compiled from `src/hello.warm` keeps.
  defp compiled(%{ns: ns} = project) do
    beam = Path.join(ebin(project), "Elixir.#{ns}.Hello.beam")

    {:ok, {_, [attributes: attributes]}} =
      :beam_lib.chunks(String.to_charlist(beam), [:attributes])

    [text] = Keyword.fetch!(attributes, :warm)
    text
  end

  # Puts in the language's place what roux 0.1 compiled from it: no
  # format stamp, definitions of the old shape, and a query that
  # raises, should anything of it run. Compiled here, it is unloaded
  # at once.
  defp plant_stale_language!(%{ns: ns} = project) do
    module = Module.concat(ns, Lang)

    source = """
    defmodule #{inspect(module)} do
      @behaviour Roux.Lang
      def file_extensions, do: [".warm"]
      def compile_query, do: :warm_compile
      def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

      def warm_compile(db, path) do
        Roux.Runtime.execute(db, :warm_compile, path, fn _db, _path ->
          raise "the language compiled against another roux ran"
        end)
      end

      def __roux_queries__ do
        definition = %Roux.Query.Definition{
          name: :warm_compile,
          module: __MODULE__,
          function: :warm_compile
        }

        %{
          queries: [Map.drop(definition, [:code, :version, :store, :transient])],
          inputs: [%Roux.Input.Definition{name: :source_text, durability: :low}],
          entities: []
        }
      end
    end
    """

    [{^module, binary}] = Code.compile_string(source, "stale_lang.ex")
    :code.purge(module)
    :code.delete(module)
    File.write!(Path.join(ebin(project), "Elixir.#{inspect(module)}.beam"), binary)
  end

  test "a cold build compiles the sources in the same run", %{tmp_dir: tmp_dir} do
    project = project!(tmp_dir)

    assert {output, 0} = build(project)
    assert output =~ "Compiling 1 file (.warm)"
    assert compiled(project) == "one"

    assert {output, 0} = build(project)
    refute output =~ "Compiling"
  end

  # A roux upgrade: the build's language was compiled against the roux
  # before, which Mix recompiles, but only once `:roux` has run.
  test "a language compiled against another roux is recompiled before it runs",
       %{tmp_dir: tmp_dir} do
    project = project!(tmp_dir)
    assert {_, 0} = build(project)

    plant_stale_language!(project)
    File.write!(Path.join(tmp_dir, "lib/lang.ex"), "# recompiled\n", [:append])
    File.write!(Path.join(tmp_dir, "src/hello.warm"), "two\n")

    assert {output, 0} = build(project)
    assert output =~ "Compiling 1 file (.ex)"
    assert output =~ "Compiling 1 file (.warm)"
    refute output =~ "KeyError"
    assert compiled(project) == "two"
  end

  test "a language compiled against another roux that Mix does not recompile fails the build",
       %{tmp_dir: tmp_dir} do
    project = project!(tmp_dir)
    assert {_, 0} = build(project)

    plant_stale_language!(project)
    File.write!(Path.join(tmp_dir, "src/hello.warm"), "two\n")

    assert {output, status} = build(project)
    assert status != 0
    # Compiled from no file left, it is told of at the project file.
    assert output =~
             "mix.exs:1: error: #{project.ns}.Lang was compiled against a roux older " <>
               "than definition formats"

    assert output =~ "mix compile --force recompiles the project's modules"
    refute output =~ "the language compiled against another roux ran"
    assert compiled(project) == "one"
  end
end
