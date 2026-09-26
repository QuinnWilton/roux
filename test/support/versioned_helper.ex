defmodule Roux.Test.VersionedHelper do
  @moduledoc false

  def len(value), do: byte_size(value)
  def roots, do: [Roux.Test.SampleEntity]
end
