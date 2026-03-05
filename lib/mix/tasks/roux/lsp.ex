defmodule Mix.Tasks.Roux.Lsp do
  @moduledoc """
  Starts the Roux LSP server over stdio.

  The server reads language configuration from the `:roux` key in
  `Mix.Project.config/0` and registers all languages with a fresh
  database before accepting LSP protocol messages.

  ## Usage

      mix roux.lsp

  ## Configuration

      # In mix.exs project/0:
      def project do
        [
          ...,
          roux: [languages: [MyLang]]
        ]
      end
  """

  @shortdoc "Starts the Roux LSP server over stdio"

  use Mix.Task

  @impl true
  def run(_argv) do
    # LSP uses stdout for JSON-RPC. Silence Mix shell output so compilation
    # messages don't corrupt the protocol stream. Logger is redirected to
    # stderr via config :logger, :default_handler.
    Mix.shell(Mix.Shell.Quiet)

    Mix.Task.run("app.start")

    roux_config = Mix.Project.config()[:roux] || []
    languages = Keyword.get(roux_config, :languages, [])

    {:ok, buffer} =
      GenLSP.Buffer.start_link(communication: {GenLSP.Communication.Stdio, []})

    {:ok, assigns} = GenLSP.Assigns.start_link()
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, _pid} =
      GenLSP.start_link(Roux.Lang.LSP, [languages: languages],
        buffer: buffer,
        assigns: assigns,
        task_supervisor: task_supervisor
      )

    Process.sleep(:infinity)
  end
end
