# Concuerror test modules for Roux.Intern.
#
# Each module exercises a specific concurrent race condition with 2–3
# processes. Concuerror systematically explores all scheduler interleavings
# and verifies the assertions hold in every case.
#
# Run with:
#   mix concuerror -m Roux.Concurrency.InternSameValueTest
#   mix concuerror --all

defmodule Roux.Concurrency.InternSameValueTest do
  @moduledoc """
  3 processes intern the same value simultaneously.
  All must receive the same ID.
  """

  def test do
    table = Roux.Intern.new(:test)
    parent = self()

    for _ <- 1..3 do
      spawn(fn ->
        id = Roux.Intern.intern(table, "hello")
        send(parent, {:result, id})
      end)
    end

    id1 = receive(do: ({:result, id} -> id))
    id2 = receive(do: ({:result, id} -> id))
    id3 = receive(do: ({:result, id} -> id))

    ^id1 = id2
    ^id1 = id3

    Roux.Intern.destroy(table)
  end
end

defmodule Roux.Concurrency.InternDistinctValuesTest do
  @moduledoc """
  3 processes intern different values simultaneously.
  All must receive distinct IDs.
  """

  def test do
    table = Roux.Intern.new(:test)
    parent = self()

    spawn(fn -> send(parent, {:a, Roux.Intern.intern(table, "a")}) end)
    spawn(fn -> send(parent, {:b, Roux.Intern.intern(table, "b")}) end)
    spawn(fn -> send(parent, {:c, Roux.Intern.intern(table, "c")}) end)

    results =
      for _ <- 1..3, into: %{} do
        receive do
          {key, id} -> {key, id}
        end
      end

    # All three IDs must be distinct.
    ids = Map.values(results)
    3 = length(Enum.uniq(ids))

    Roux.Intern.destroy(table)
  end
end

defmodule Roux.Concurrency.InternResolveRaceTest do
  @moduledoc """
  One process interns a new value while another resolves an existing one.
  Resolve must never return stale or partial data.
  """

  def test do
    table = Roux.Intern.new(:test)
    parent = self()

    # Pre-intern so resolve has a valid target.
    id = Roux.Intern.intern(table, "existing")

    spawn(fn ->
      _new_id = Roux.Intern.intern(table, "new_value")
      send(parent, :intern_done)
    end)

    spawn(fn ->
      {:ok, "existing"} = Roux.Intern.resolve(table, id)
      send(parent, :resolve_done)
    end)

    receive(do: (:intern_done -> :ok))
    receive(do: (:resolve_done -> :ok))

    Roux.Intern.destroy(table)
  end
end

defmodule Roux.Concurrency.InternLookupRaceTest do
  @moduledoc """
  One process interns a value while another looks it up concurrently.
  Lookup must return either :error (not yet visible) or {:ok, id} with
  a valid positive integer — never partial or inconsistent data.
  """

  def test do
    table = Roux.Intern.new(:test)
    parent = self()

    spawn(fn ->
      Roux.Intern.intern(table, "value")
      send(parent, :intern_done)
    end)

    spawn(fn ->
      case Roux.Intern.lookup(table, "value") do
        :error -> :ok
        {:ok, id} when is_integer(id) and id > 0 -> :ok
      end

      send(parent, :lookup_done)
    end)

    receive(do: (:intern_done -> :ok))
    receive(do: (:lookup_done -> :ok))

    Roux.Intern.destroy(table)
  end
end
