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

defmodule Roux.Concurrency.InternRestoredLoadRaceTest do
  @moduledoc """
  A table restored from an encoded snapshot loads its rows on the first
  miss. Three processes miss at once: one interns a restored value, one
  interns a new value, one resolves a restored ID. Every interleaving of
  their loads must keep the restored ID, give the new value an ID past
  the restored counter, and resolve both.
  """

  def test do
    table = Roux.Intern.new(:test)

    :ok =
      Roux.Intern.restore(table, %{
        version: 3,
        forward: :erlang.term_to_binary([{"a", 1}]),
        counter: 1
      })

    parent = self()

    spawn(fn -> send(parent, {:restored, Roux.Intern.intern(table, "a")}) end)
    spawn(fn -> send(parent, {:new, Roux.Intern.intern(table, "b")}) end)
    spawn(fn -> send(parent, {:resolved, Roux.Intern.resolve(table, 1)}) end)

    1 = receive(do: ({:restored, id} -> id))
    new_id = receive(do: ({:new, id} -> id))
    {:ok, "a"} = receive(do: ({:resolved, result} -> result))

    true = new_id > 1
    {:ok, "b"} = Roux.Intern.resolve(table, new_id)
    {:ok, ^new_id} = Roux.Intern.lookup(table, "b")
    2 = Roux.Intern.size(table)

    Roux.Intern.destroy(table)
  end
end

defmodule Roux.Concurrency.InternRestoredSnapshotRaceTest do
  @moduledoc """
  A restored table is looked up and snapshotted while another process
  interns a new value into it. The lookup must find the restored value
  whichever load it races, and the snapshot must hold every restored row
  under a counter at least as high as every ID it holds, whether it hands
  back the restored encoding or encodes the loaded table.
  """

  def test do
    table = Roux.Intern.new(:test)

    :ok =
      Roux.Intern.restore(table, %{
        version: 3,
        forward: :erlang.term_to_binary([{"a", 1}]),
        counter: 1
      })

    parent = self()

    spawn(fn -> send(parent, {:lookup, Roux.Intern.lookup(table, "a")}) end)
    spawn(fn -> send(parent, {:new, Roux.Intern.intern(table, "b")}) end)
    spawn(fn -> send(parent, {:snapshot, Roux.Intern.encode_snapshot(table)}) end)

    {:ok, 1} = receive(do: ({:lookup, result} -> result))
    new_id = receive(do: ({:new, id} -> id))
    %{version: 3, forward: forward, counter: counter} = receive(do: ({:snapshot, s} -> s))

    rows = :erlang.binary_to_term(forward)
    true = {"a", 1} in rows
    true = Enum.all?(rows, fn {_value, id} -> id <= counter end)
    true = Enum.all?(rows, fn row -> row in [{"a", 1}, {"b", new_id}] end)

    Roux.Intern.destroy(table)
  end
end

defmodule Roux.Concurrency.InternSnapshotCounterRaceTest do
  @moduledoc """
  Two processes intern new values while a third encodes a snapshot. The
  snapshot's counter must be at least every ID its rows hold: a table
  restored from it takes new IDs from that counter, and one at or below a
  row's ID would give two values the same ID.
  """

  def test do
    table = Roux.Intern.new(:test)
    parent = self()

    spawn(fn -> send(parent, {:a, Roux.Intern.intern(table, "a")}) end)
    spawn(fn -> send(parent, {:b, Roux.Intern.intern(table, "b")}) end)
    spawn(fn -> send(parent, {:snapshot, Roux.Intern.encode_snapshot(table)}) end)

    %{forward: forward, counter: counter} = receive(do: ({:snapshot, s} -> s))
    receive(do: ({:a, _} -> :ok))
    receive(do: ({:b, _} -> :ok))

    true = Enum.all?(:erlang.binary_to_term(forward), fn {_value, id} -> id <= counter end)

    Roux.Intern.destroy(table)
  end
end
