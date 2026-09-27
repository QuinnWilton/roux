defmodule Roux.Query.FormatError do
  @moduledoc """
  Raised when registering a module of queries compiled against a roux
  whose definition format is not this one's (`Roux.Query.format/0`):
  what it generated is not what this roux reads, so none of it runs.
  `format` is the module's (nil for a roux older than the stamp: 0.1
  and the 0.2 development builds before it), `expected` this roux's.
  """

  @type t :: %__MODULE__{module: module(), format: pos_integer() | nil, expected: pos_integer()}

  defexception [:module, :format, :expected]

  @impl true
  def message(%__MODULE__{module: module, format: format, expected: expected}) do
    compiled =
      case format do
        nil -> "a roux older than definition formats"
        format when format > expected -> "a newer roux (definition format #{format})"
        format -> "an older roux (definition format #{format})"
      end

    "#{inspect(module)} was compiled against #{compiled}, and this roux reads " <>
      "definition format #{expected}: recompile it against this roux"
  end
end
