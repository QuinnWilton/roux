defmodule Roux.Test.SampleEntity do
  @moduledoc false
  use Roux.Entity,
    identity: [:name],
    tracked: [:body, :return_type]
end
