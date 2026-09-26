defmodule Roux.Test.AroundQueries do
  @moduledoc false
  # Every body runs inside around/2, which reads an input on the body's
  # behalf: the read becomes the query's dependency.
  use Roux.Query, around: {Roux.Test.AroundQueries, :around}

  definput :around_src, durability: :medium
  definput :around_extra, durability: :medium

  defquery :wrapped, key: key do
    {:body, Roux.Runtime.input!(db, :around_src, key)}
  end

  @spec around(map(), (-> term())) :: term()
  def around(%{db: db, query: query, key: key}, body) do
    extra = Roux.Runtime.input(db, :around_extra, key, default: 0)
    {query, extra, body.()}
  end
end
