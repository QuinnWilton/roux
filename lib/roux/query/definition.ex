defmodule Roux.Query.Definition do
  @moduledoc """
  Describes a derived query: its name, the module and function that implement
  it, and any additional options.

  Used by the `defquery` macro to record metadata that `Roux.Database` reads
  during module registration.

  `code` and `version` make up the query's code version (see
  `Roux.Query`): the roots its code is read from beyond its own module
  (a list of modules, or `{module, function, args}` returning one), and
  a term a query's author bumps by hand.

  `store` and `transient` are how a manifest keeps the query's entries
  (see `Roux.Query`): `transient` names the function the `defquery`
  generated from its `transient:` predicate.
  """

  @type code :: [module()] | {module(), atom(), [term()]} | nil

  @type t :: %__MODULE__{
          name: atom(),
          module: module(),
          function: atom(),
          opts: keyword(),
          code: code(),
          version: term(),
          store: :inline | :blob | :none,
          transient: {module(), atom()} | nil
        }

  @enforce_keys [:name, :module, :function]
  defstruct [
    :name,
    :module,
    :function,
    opts: [],
    code: nil,
    version: nil,
    store: :inline,
    transient: nil
  ]

  @doc """
  Creates a new query definition.
  """
  @spec new(atom(), module(), atom(), keyword()) :: t()
  def new(name, module, function, opts \\ [])
      when is_atom(name) and is_atom(module) and is_atom(function) and is_list(opts) do
    %__MODULE__{name: name, module: module, function: function, opts: opts}
  end
end
