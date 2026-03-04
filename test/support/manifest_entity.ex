defmodule Roux.Test.ManifestEntity do
  @moduledoc false
  use Roux.Entity,
    identity: [:name],
    tracked: []
end
