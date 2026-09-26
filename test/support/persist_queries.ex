defmodule Roux.Test.PersistQueries do
  @moduledoc false
  # Queries whose entries a manifest keeps, or not (`store:`,
  # `transient:`): a fact that can be lost, the readers above it, and one
  # never kept at all.
  use Roux.Query

  definput :psrc, durability: :medium

  defquery :p_fact, key: key, transient: &match?({:error, :lost}, &1) do
    case Roux.Runtime.input(db, :psrc, key) do
      :lost -> {:error, :lost}
      value -> {:ok, value}
    end
  end

  defquery :p_reader, key: key do
    {:read, Roux.Runtime.query(db, :p_fact, key)}
  end

  defquery :p_top, key: key do
    {:top, Roux.Runtime.query(db, :p_reader, key)}
  end

  defquery :p_none, key: key, store: :none do
    Roux.Runtime.input(db, :psrc, key)
  end

  defquery :p_blob, key: key, store: :blob do
    Roux.Runtime.input(db, :psrc, key)
  end
end
