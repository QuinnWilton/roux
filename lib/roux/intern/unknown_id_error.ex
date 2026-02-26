defmodule Roux.Intern.UnknownIdError do
  @moduledoc """
  Raised when attempting to resolve an intern ID that does not exist.
  """

  defexception [:id]

  @type t :: %__MODULE__{id: pos_integer()}

  @impl true
  def message(%__MODULE__{id: id}) do
    "unknown intern ID: #{id}"
  end
end
