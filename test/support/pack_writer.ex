defmodule Roux.Test.PackWriter do
  @moduledoc """
  Writes one trace in a trace pack's group, for a race test to run in a
  VM of its own (`Roux.Test.RawGate`): a function the test defines is
  not loaded there.
  """

  alias Roux.Blob
  alias Roux.Blob.Trace.Pack

  @doc "Puts `value` under `name` in `group`, flushing the group's pack."
  @spec write(Blob.t(), term(), term(), term()) :: :ok
  def write(store, group, name, value) do
    Pack.with_group(store, group, fn -> Pack.put(store, name, [{:dep, 1}], value) end)
  end
end
