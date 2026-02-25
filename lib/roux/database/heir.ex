defmodule Roux.Database.Heir do
  @moduledoc """
  Preserves ETS tables across `Roux.Database.TableOwner` crashes.

  When TableOwner dies, ETS automatically transfers all heir-protected tables
  to this process via `ETS-TRANSFER` messages. The new TableOwner calls
  `reclaim/1` in its `init/1` to get them back. During normal operation this
  process is idle.

  Started before TableOwner under a `:rest_for_one` supervisor. Its PID is
  published via `:persistent_term` so TableOwner can find it without passing
  PIDs through the supervisor spec.
  """

  use GenServer

  @type tables :: %{atom() => :ets.tid()}

  # -- Client API --

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Reclaims all tables held by the heir process.

  Called by a freshly started TableOwner. The heir gives away each table to
  the caller and returns the table map. Returns `{:ok, %{}}` when no tables
  are held (fresh start).
  """
  @spec reclaim(pid()) :: {:ok, tables()}
  def reclaim(heir_pid) do
    GenServer.call(heir_pid, :reclaim)
  end

  @doc """
  Reads the heir PID from persistent_term for the given supervisor.
  """
  @spec whereis(pid()) :: pid()
  def whereis(sup_pid) do
    :persistent_term.get({__MODULE__, sup_pid})
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    sup_pid = Keyword.fetch!(opts, :sup_pid)
    :persistent_term.put({__MODULE__, sup_pid}, self())
    {:ok, %{tables: %{}, sup_pid: sup_pid}}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", table, _from, tag}, state) do
    {:noreply, put_in(state.tables[tag], table)}
  end

  @impl true
  def handle_call(:reclaim, {caller, _ref}, state) do
    for {_tag, table} <- state.tables do
      :ets.give_away(table, caller, :reclaimed)
    end

    {:reply, {:ok, state.tables}, %{state | tables: %{}}}
  end

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, state.sup_pid})
    :ok
  end
end
