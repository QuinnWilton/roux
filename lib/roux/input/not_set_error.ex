defmodule Roux.Input.NotSetError do
  @moduledoc """
  Raised when reading an input key that has never been set.
  """

  @type t :: %__MODULE__{
          input_name: atom(),
          key: term()
        }

  defexception [:input_name, :key]

  @impl true
  def message(%__MODULE__{input_name: name, key: key}) do
    "input #{inspect(name)} has not been set for key #{inspect(key)}"
  end
end
