defmodule Roux.Blob.MissingError do
  @moduledoc """
  Raised by `Roux.Blob.fetch!/2` for a digest the store holds no entry
  for: never written, collected, or found corrupt.
  """

  @type t :: %__MODULE__{store: Path.t(), digest: String.t()}

  defexception [:store, :digest]

  @impl true
  def message(%__MODULE__{store: store, digest: digest}) do
    "blob #{digest} is not in the store at #{store}"
  end
end
