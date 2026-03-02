defmodule Roux.Test.RuntimeTestQueries do
  @moduledoc false

  # Simple query functions for Runtime tests that need registered queries.
  # Each function calls Runtime.execute/4 internally, matching the defquery pattern.

  def upper(db, key) do
    Roux.Runtime.execute(db, :upper, key, fn db, key ->
      val = Roux.Runtime.input(db, :source, key)
      String.upcase(val)
    end)
  end

  def length_query(db, key) do
    Roux.Runtime.execute(db, :length_query, key, fn db, key ->
      val = Roux.Runtime.input(db, :source, key)
      String.length(val)
    end)
  end
end
