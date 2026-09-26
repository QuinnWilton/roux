defmodule Roux.Test.HandBumpedQueries do
  @moduledoc false
  # No code versions: a `version:` alone.
  use Roux.Query

  defquery :bumped_only, key: key, version: {:format, 3} do
    key
  end

  defquery :unversioned, key: key do
    key
  end
end
