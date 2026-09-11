defmodule Roux.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/QuinnWilton/roux"

  def project do
    [
      app: :roux,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ],

      # Hex
      description: "A framework for building incremental mix compilers",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/concurrency"]
  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      # hex: {:gen_lsp, "~> 0.11.0"}
      {:gen_lsp,
       github: "QuinnWilton/gen_lsp", branch: "fix/beam-box/tcp-read-crash", override: true},
      {:assert_boundary, "~> 0.1.0", only: :test, runtime: false},
      {:concuerror,
       github: "QuinnWilton/Concuerror", only: :test, runtime: false, manager: :rebar3},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/editors/zed mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "Roux",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
