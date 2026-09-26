defmodule Roux.Blob.FormatError do
  @moduledoc """
  Raised by `Roux.Blob.open!/1` for a directory holding a store of
  another layout: its `FORMAT` file names another version.
  """

  @type t :: %__MODULE__{root: Path.t(), found: String.t()}

  defexception [:root, :found]

  @impl true
  def message(%__MODULE__{root: root, found: found}) do
    "#{root} holds a blob store of another layout (#{inspect(String.trim(found))}); " <>
      "remove it, or open another directory"
  end
end
