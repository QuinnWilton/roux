defmodule Roux.Test.MultiIdEntity do
  @moduledoc false
  use Roux.Entity,
    identity: [:module_name, :name],
    tracked: [:arity]
end
