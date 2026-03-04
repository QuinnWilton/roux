defmodule Mix.Tasks.Compile.Roux do
  @moduledoc """
  Mix compiler task for Roux languages.

  Add `:roux` to your project's compilers list:

      def project do
        [
          compilers: [:roux] ++ Mix.compilers(),
          # ...
        ]
      end

  All logic is in `Roux.Lang.Compiler` — this module is a thin shim
  so Mix discovers it via the `:roux` compiler name.
  """

  use Mix.Task.Compiler

  @impl true
  defdelegate run(argv), to: Roux.Lang.Compiler

  @impl true
  defdelegate manifests(), to: Roux.Lang.Compiler

  @impl true
  defdelegate clean(), to: Roux.Lang.Compiler
end
