# Concuerror test modules for Roux.Database ETS crash recovery.
#
# These test the Heir/TableOwner protocol under concurrent interleavings.
# Uses manual process wiring (not the full OTP supervisor) to keep the
# state space small enough for exhaustive exploration.
#
# Run with:
#   mix concuerror -m Roux.Concurrency.DatabaseWriteDuringCrashTest
#   mix concuerror --all

defmodule Roux.Concurrency.DatabaseWriteDuringCrashTest do
  @moduledoc """
  One process writes to a public ETS table while the table's owner is
  killed concurrently. The table has heir protection, so it survives.

  The write must always complete successfully — public ETS tables remain
  accessible during ownership transfers.
  """

  def concuerror_options, do: [treat_as_normal: [:killed]]

  def test do
    parent = self()
    heir = spawn(fn -> heir_loop() end)

    # Owner creates a heir-protected table, then blocks.
    owner =
      spawn(fn ->
        tid = :ets.new(:test, [:set, :public, {:heir, heir, :test}])
        send(parent, {:table, tid})
        receive(do: (:never -> :ok))
      end)

    tid = receive(do: ({:table, t} -> t))

    # Writer and killer run concurrently.
    spawn(fn ->
      :ets.insert(tid, {:key, :value})
      send(parent, :write_done)
    end)

    spawn(fn ->
      Process.exit(owner, :kill)
      send(parent, :kill_done)
    end)

    receive(do: (:write_done -> :ok))
    receive(do: (:kill_done -> :ok))

    # Table survived (heir took over) and write completed.
    [{:key, :value}] = :ets.lookup(tid, :key)

    send(heir, :done)
  end

  defp heir_loop do
    receive do
      {:"ETS-TRANSFER", _tid, _from, _tag} -> heir_loop()
      :done -> :ok
    end
  end
end

defmodule Roux.Concurrency.DatabaseReclaimRaceTest do
  @moduledoc """
  After a table owner dies, ETS-TRANSFER messages arrive at the heir process.
  A new owner then calls reclaim. Verifies that the heir returns all tables
  and none are lost.

  Uses Process.monitor to confirm owner death before reclaiming — matching
  the real protocol where the supervisor only starts a new TableOwner after
  the old one exits.
  """

  def concuerror_options, do: [treat_as_normal: [:killed]]

  def test do
    heir = spawn(fn -> heir_loop(%{}) end)

    # Create two tables with heir protection.
    tid1 = :ets.new(:t1, [:set, :public, {:heir, heir, :t1}])
    tid2 = :ets.new(:t2, [:set, :public, {:heir, heir, :t2}])
    :ets.insert(tid1, {:k1, :v1})
    :ets.insert(tid2, {:k2, :v2})

    # Give tables to a temporary owner.
    owner = spawn(fn -> receive(do: (:never -> :ok)) end)
    :ets.give_away(tid1, owner, :given)
    :ets.give_away(tid2, owner, :given)

    # Wait for owner to actually die before reclaiming.
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    receive(do: ({:DOWN, ^ref, :process, ^owner, _} -> :ok))

    # Reclaim — simulates new TableOwner calling Heir.reclaim/1 in init.
    send(heir, {:reclaim, self()})
    tables = receive(do: ({:tables, t} -> t))

    # All tables must be accounted for.
    2 = map_size(tables)
    ^tid1 = Map.fetch!(tables, :t1)
    ^tid2 = Map.fetch!(tables, :t2)

    # Data survived the ownership transfer.
    [{:k1, :v1}] = :ets.lookup(tid1, :k1)
    [{:k2, :v2}] = :ets.lookup(tid2, :k2)

    send(heir, :done)
  end

  defp heir_loop(tables) do
    receive do
      {:"ETS-TRANSFER", tid, _from, tag} ->
        heir_loop(Map.put(tables, tag, tid))

      {:reclaim, caller} ->
        send(caller, {:tables, tables})
        heir_loop(%{})

      :done ->
        :ok
    end
  end
end
