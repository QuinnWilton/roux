defmodule Roux.Input.Definition do
  @moduledoc """
  Describes an input: its name and how often it changes (durability).

  Durability controls how aggressively the validation algorithm can skip
  revalidation of queries rooted in this input.
  """

  @type t :: %__MODULE__{
          name: atom(),
          durability: Roux.Revision.durability()
        }

  @enforce_keys [:name, :durability]
  defstruct [:name, :durability]
end
