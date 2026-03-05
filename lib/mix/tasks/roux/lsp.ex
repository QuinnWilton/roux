defmodule Mix.Tasks.Roux.Lsp do
  @moduledoc """
  Starts the Roux LSP server over stdio.

  The server reads language configuration from the `:roux` application
  environment (`:languages` key) and registers all languages with a fresh
  database before accepting LSP protocol messages.

  ## Usage

      mix roux.lsp

  ## Configuration

      # In config.exs:
      config :roux,
        languages: [MyLang]
  """

  use Mix.Task

  @impl true
  def run(_argv) do
    # LSP uses stdout for JSON-RPC. Silence Mix shell output so compilation
    # messages don't corrupt the protocol stream. Logger is redirected to
    # stderr via config :logger, :default_handler.
    Mix.shell(Mix.Shell.Quiet)

    Mix.Task.run("app.start")

    languages = Application.get_env(:roux, :languages, [])

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
