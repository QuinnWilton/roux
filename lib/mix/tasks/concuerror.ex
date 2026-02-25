defmodule Mix.Tasks.Concuerror do
  @shortdoc "Run Concuerror concurrency tests"

  @moduledoc """
  Runs Concuerror tests for exhaustive scheduler interleaving exploration.

  ## Usage

      # Run a single test module
      mix concuerror -m Roux.Concurrency.InternSameValueTest

      # Run all Roux.Concurrency.* modules
      mix concuerror --all

  ## Options

    * `-m` / `--module` — test module to run
    * `--all` — run every `Roux.Concurrency.*` module
    * `--dpor` — DPOR algorithm, `optimal` (default) or `source`
    * `--interleaving-bound` — bound on interleavings explored (default: unbounded)
    * `--treat-as-normal` — exit reasons to treat as normal (can be repeated)

  Each test module must export a 0-arity `test/0` function.
  """

  use Mix.Task

  @namespace Roux.Concurrency

  @impl Mix.Task
  def run(args) do
    Mix.env(:test)
    Mix.Task.run("compile", [])

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          module: :string,
          all: :boolean,
          dpor: :string,
          interleaving_bound: :integer,
          treat_as_normal: :keep
        ],
        aliases: [m: :module]
      )

    modules =
      cond do
        opts[:all] -> discover_modules()
        opts[:module] -> [Module.concat([opts[:module]])]
        true -> Mix.raise("Provide --module (-m) or --all")
      end

    results = Enum.map(modules, &run_one(&1, opts))

    failures = Enum.count(results, &(&1 != :ok))

    if failures > 0 do
      Mix.raise("#{failures} Concuerror test(s) failed")
    end
  end

  defp run_one(module, opts) do
    Mix.shell().info("concuerror: #{inspect(module)}")

    pa_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    concuerror_opts =
      [
        {:module, module},
        {:test, :test},
        {:verbosity, 1}
      ] ++
        Enum.map(pa_paths, &{:pa, to_charlist(&1)}) ++
        dpor_opts(opts) ++
        bound_opts(opts) ++
        treat_as_normal_opts(opts)

    # :concuerror.run/1 returns :ok | :error | :fail.
    # Called via apply/3 to avoid a compile-time reference — concuerror is
    # a test-only dependency and isn't available in dev.
    case apply(:concuerror, :run, [concuerror_opts]) do
      :ok ->
        Mix.shell().info("  passed")
        :ok

      :error ->
        Mix.shell().error("  FAILED: errors found (see concuerror_report.txt)")
        :error

      :fail ->
        Mix.shell().error("  FAILED: analysis could not complete")
        :fail
    end
  end

  defp dpor_opts(opts) do
    case opts[:dpor] do
      "source" -> [{:dpor, :source}]
      _ -> [{:dpor, :optimal}]
    end
  end

  defp bound_opts(opts) do
    case opts[:interleaving_bound] do
      nil -> []
      n -> [{:interleaving_bound, n}]
    end
  end

  defp treat_as_normal_opts(opts) do
    opts
    |> Keyword.get_values(:treat_as_normal)
    |> Enum.map(&{:treat_as_normal, String.to_atom(&1)})
  end

  defp discover_modules do
    {:ok, modules} = :application.get_key(:roux, :modules)

    modules
    |> Enum.filter(&under_namespace?/1)
    |> Enum.sort()
  end

  defp under_namespace?(mod) do
    prefix = Atom.to_string(@namespace) <> "."
    String.starts_with?(Atom.to_string(mod), prefix)
  end
end
