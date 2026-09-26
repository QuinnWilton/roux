defmodule Roux.Test.FanOutQueries do
  @moduledoc false
  # A fan-out and its members. A member reports to the process named by
  # the `:fan_probe` input (when set) as it starts, and waits for a `:go`
  # when told to: a test can hold members open to see them run side by
  # side. The probe is read around roux, not as a dependency.
  use Roux.Query

  definput :fan_src, durability: :medium
  definput :fan_probe, durability: :high

  defquery :fan_member, key: key do
    value = Roux.Runtime.input(db, :fan_src, key)

    case Roux.Input.fetch(db, :fan_probe, :pid) do
      :error ->
        :ok

      {:ok, pid} ->
        send(pid, {:member_started, key, self()})

        if Roux.Input.fetch(db, :fan_probe, :hold) == {:ok, true} do
          receive do
            :go -> :ok
          end
        end
    end

    case value do
      {:raise, message} -> raise message
      {:cycle, parent_key} -> Roux.Runtime.query(db, :fan_parent, parent_key)
      value -> {:member, value}
    end
  end

  defquery :fan_parent, key: keys do
    {:parent, Roux.Runtime.parallel(db, Enum.map(keys, &{:fan_member, &1}))}
  end

  defquery :fan_parity, key: key do
    [{:member, value}] = Roux.Runtime.parallel(db, [{:fan_member, key}], max_concurrency: 1)
    rem(value, 2)
  end
end
