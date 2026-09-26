defmodule Roux.Test.VersionedQueries do
  @moduledoc false
  # Queries versioned by their module's code (`use Roux.Query, code:`),
  # with a derived root and a hand-bumped version beside it.
  use Roux.Query, code: [exclude: [Roux.Test.VersionedHelper]]

  definput :vsrc, durability: :medium

  defquery :versioned_len, key: key do
    value = Roux.Runtime.input(db, :vsrc, key)
    {Roux.Test.VersionedHelper.len(value), Roux.Runtime.code_version()}
  end

  defquery :versioned_rooted, key: key, code: {Roux.Test.VersionedHelper, :roots, []} do
    Roux.Runtime.input(db, :vsrc, key)
  end

  defquery :versioned_bumped, key: key, version: 2 do
    Roux.Runtime.input(db, :vsrc, key)
  end
end
