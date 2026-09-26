# Concuerror test modules for fan-out groups (`Roux.Runtime.parallel/3`).
#
# Run with:
#   MIX_ENV=test mix concuerror -m Roux.Concurrency.GroupValidationTest
#   MIX_ENV=test mix concuerror --all

defmodule Roux.Concurrency.GroupValidationTest do
  @moduledoc """
  A process demands a fan-out whose group went stale. Validating the
  group brings both members up to date at once, each in a worker of its
  own, while the process waits for them. It must see the new value, the
  stale member must hold it, and no claim may be left behind.
  """

  alias Roux.{Memo, Runtime}
  alias Roux.Test.GroupFixture

  def concuerror_options do
    [treat_as_normal: [:shutdown], depth_bound: 5_000]
  end

  def test do
    members = ["a", "b"]
    db = GroupFixture.stale_fan_out(members)
    parent = self()

    spawn(fn ->
      send(parent, {:group, Runtime.execute(db, :fan_out, members, &GroupFixture.fan_out/2)})
    end)

    ["Z", "Y"] = receive(do: ({:group, r} -> r))

    {:ok, %{value: "Z"}} = Memo.get(db, {:upper, "a"})
    {:ok, %{value: ["Z", "Y"]}} = Memo.get(db, {:fan_out, members})
    [] = :ets.tab2list(db.dedup_table)

    GroupFixture.cleanup(db)
  end
end

defmodule Roux.Concurrency.GroupMemberRaceTest do
  @moduledoc """
  One process demands a fan-out whose group went stale while another
  demands the stale member directly. The first validates the group,
  bringing its member up to date in a worker of its own; whichever of
  the worker and the other process gets to the member first computes
  it, and the other waits. Both must see the new value, and no claim
  may be left behind. (A group of one: two members and a third process
  are more interleavings than a CI job can explore.)
  """

  alias Roux.{Memo, Runtime}
  alias Roux.Test.{GroupFixture, RuntimeTestQueries}

  # Four processes touching one key: explored with up to four
  # preemptions each, the whole state space being too large for a CI job.
  def concuerror_options do
    [treat_as_normal: [:shutdown], depth_bound: 5_000, dpor: :source, scheduling_bound: 4]
  end

  def test do
    members = ["a"]
    db = GroupFixture.stale_fan_out(members)
    parent = self()

    spawn(fn ->
      send(parent, {:group, Runtime.execute(db, :fan_out, members, &GroupFixture.fan_out/2)})
    end)

    spawn(fn -> send(parent, {:member, RuntimeTestQueries.upper(db, "a")}) end)

    ["Z"] = receive(do: ({:group, r} -> r))
    "Z" = receive(do: ({:member, r} -> r))

    {:ok, %{value: "Z"}} = Memo.get(db, {:upper, "a"})
    {:ok, %{value: ["Z"]}} = Memo.get(db, {:fan_out, members})
    [] = :ets.tab2list(db.dedup_table)

    GroupFixture.cleanup(db)
  end
end

defmodule Roux.Concurrency.GroupValidatorsTest do
  @moduledoc """
  Two processes demand the same fan-out whose group went stale. Each
  validates the group, bringing its members up to date in workers of
  its own, so two workers race for the stale member while the other
  member is merely validated twice. Both must see the new value, and no
  claim may be left behind.
  """

  alias Roux.{Memo, Runtime}
  alias Roux.Test.GroupFixture

  # Six processes: explored with up to two preemptions each.
  def concuerror_options do
    [treat_as_normal: [:shutdown], depth_bound: 5_000, dpor: :source, scheduling_bound: 2]
  end

  def test do
    members = ["a", "b"]
    db = GroupFixture.stale_fan_out(members)
    parent = self()

    for tag <- [:r1, :r2] do
      spawn(fn ->
        send(parent, {tag, Runtime.execute(db, :fan_out, members, &GroupFixture.fan_out/2)})
      end)
    end

    ["Z", "Y"] = receive(do: ({:r1, r} -> r))
    ["Z", "Y"] = receive(do: ({:r2, r} -> r))

    {:ok, %{value: "Z"}} = Memo.get(db, {:upper, "a"})
    {:ok, %{value: ["Z", "Y"]}} = Memo.get(db, {:fan_out, members})
    [] = :ets.tab2list(db.dedup_table)

    GroupFixture.cleanup(db)
  end
end
