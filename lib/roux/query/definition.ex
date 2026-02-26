defmodule Roux.Query.Definition do
  @moduledoc """
  Describes a derived query: its name, the module and function that implement
  it, and any additional options.

  Used by the `defquery` macro to record metadata that `Roux.Database` reads
  during module registration.
  """

  @type t :: %__MODULE__{
          name: atom(),
          module: module(),
          function: atom(),
          opts: keyword()
        }

  @enforce_keys [:name, :module, :function]
  defstruct [:name, :module, :function, opts: []]

  @doc """
  Creates a new query definition.
  """
  @spec new(atom(), module(), atom(), keyword()) :: t()
  def new(name, module, function, opts \\ [])
      when is_atom(name) and is_atom(module) and is_atom(function) and is_list(opts) do
    %__MODULE__{name: name, module: module, function: function, opts: opts}
  end
end
