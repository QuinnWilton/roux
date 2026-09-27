defmodule Roux.Test.RawGate do
  @moduledoc """
  Holds a race in `Roux.Blob` open: at the file operations a gate names,
  it runs an action after the operation completed and before the store
  sees its result. A check-then-act race in the store then happens on
  every run: the gate is the other process, acting between the check and
  the act.

  The store's file operations are raw (`Roux.Blob.IO`), past the VM's
  file server, so this hangs on `Roux.Blob.IO`'s hook rather than
  standing in for the server. Install it only in a VM of its own
  (`:peer`): while it is installed, every store operation of the VM goes
  through it.

  A gate is a map:

    * `:name` — what `uninstall/0` reports its action's result under;
    * `:ops` — the operations it watches (`:read_file`, `:write_file`,
      `:read_file_info`, `:read_link_info`, `:write_file_info`,
      `:list_dir`, `:rename` (named by its source), `:delete`,
      `:make_dir`, `:make_link` (named by the existing file));
    * `:path` — the path they name;
    * `:prefix` — true to watch every path under `:path` as well;
    * `:nth` — which of the watched operations it acts at (default 1);
    * `:action` — `{module, function, args}`, run once, in a process of
      its own that the operation waits for; its own operations pass by
      the gate, which has already acted.
  """

  @typedoc "See the moduledoc."
  @type gate :: %{
          required(:name) => term(),
          required(:ops) => [atom()],
          required(:path) => Path.t(),
          required(:action) => {module(), atom(), [term()]},
          optional(:prefix) => boolean(),
          optional(:nth) => pos_integer()
        }

  @key {__MODULE__, :gates}

  @doc "Puts `gates` in front of the store's file operations."
  @spec install([gate()]) :: :ok
  def install(gates) do
    gates = Enum.map(gates, &Map.merge(%{prefix: false, nth: 1, seen: 0, result: :not_run}, &1))
    {:ok, agent} = Agent.start(fn -> gates end)
    :persistent_term.put(@key, agent)
    Roux.Blob.IO.install_hook(&__MODULE__.at/2)
  end

  @doc """
  Takes the gates away, and returns each one's action's result by name:
  `:not_run` for a gate whose operation never came.
  """
  @spec uninstall() :: %{term() => term()}
  def uninstall do
    Roux.Blob.IO.remove_hook()

    case :persistent_term.get(@key, nil) do
      nil ->
        %{}

      agent ->
        :persistent_term.erase(@key)
        results = Agent.get(agent, &Map.new(&1, fn gate -> {gate.name, gate.result} end))
        Agent.stop(agent)
        results
    end
  end

  @doc false
  # The hook: counts the operation against the first gate still to act
  # that watches it, and runs that gate's action when this is the one it
  # waits for.
  @spec at(atom(), Path.t()) :: :ok
  def at(op, path) do
    with agent when is_pid(agent) <- :persistent_term.get(@key, nil),
         {:act, name, {module, function, args}} <-
           Agent.get_and_update(agent, &decide(&1, op, IO.chardata_to_string(path))) do
      {pid, ref} = spawn_monitor(fn -> exit({__MODULE__, apply(module, function, args)}) end)

      result =
        receive do
          {:DOWN, ^ref, :process, ^pid, {__MODULE__, result}} -> result
          {:DOWN, ^ref, :process, ^pid, reason} -> {:crashed, reason}
        end

      Agent.update(agent, fn gates ->
        Enum.map(gates, &if(&1.name == name, do: %{&1 | result: result}, else: &1))
      end)
    end

    :ok
  end

  defp decide(gates, op, path) do
    index =
      Enum.find_index(gates, fn gate ->
        gate.result == :not_run and op in gate.ops and watches?(gate, path)
      end)

    case index do
      nil ->
        {:pass, gates}

      index ->
        gate = Enum.at(gates, index)
        gate = %{gate | seen: gate.seen + 1}

        if gate.seen == gate.nth do
          {{:act, gate.name, gate.action},
           List.replace_at(gates, index, %{gate | result: :running})}
        else
          {:pass, List.replace_at(gates, index, gate)}
        end
    end
  end

  defp watches?(%{path: watched, prefix: false}, path), do: path == watched

  defp watches?(%{path: watched, prefix: true}, path),
    do: path == watched or String.starts_with?(path, watched <> "/")
end
