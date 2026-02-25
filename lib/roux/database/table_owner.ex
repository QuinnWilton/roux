defmodule Roux.Database.TableOwner do
  @moduledoc """
  Owns all framework ETS tables during normal operation.

  On startup, attempts to reclaim tables from `Roux.Database.Heir`. If no
  tables are held (fresh start or heir crash), creates them from scratch.
  All tables are created with `heir: {heir_pid, tag}` so they transfer
  automatically if this process dies.

  This process does nothing else — no computation, no message handling beyond
  table queries. Its sole purpose is to anchor ETS ownership.
  """

  use GenServer

  alias Roux.Database.Heir

  # The set of ETS tables managed by the framework.
  @table_specs %{
    memo: [:set, :public, read_concurrency: true],
    query_registry: [:set, :public],
    input_registry: [:set, :public],
    task_registry: [:set, :public, write_concurrency: true],
    dedup_table: [:set, :public, write_concurrency: true],
    intern_registry: [:set, :public],
    entity_registry: [:set, :public]
  }

  # -- Client API --

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Returns the map of `%{tag => tid}` for all managed ETS tables.
  """
  @spec get_tables(pid()) :: %{atom() => :ets.tid()}
  def get_tables(pid) do
    GenServer.call(pid, :get_tables)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    sup_pid = Keyword.fetch!(opts, :sup_pid)
    heir_pid = Heir.whereis(sup_pid)

    tables =
      case Heir.reclaim(heir_pid) do
        {:ok, reclaimed} when reclaimed != %{} -> reclaimed
        {:ok, _empty} -> create_tables(heir_pid)
      end

    {:ok, %{tables: tables, heir: heir_pid}}
  end

  @impl true
  def handle_call(:get_tables, _from, state) do
    {:reply, state.tables, state}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, :reclaimed}, state) do
    # Ignore transfer messages from give_away during reclaim.
    {:noreply, state}
  end

  # -- Private --

  defp create_tables(heir_pid) do
    Map.new(@table_specs, fn {tag, opts} ->
      # ETS heir option is a 3-tuple: {:heir, pid, heir_data}.
      tid = :ets.new(tag, [{:heir, heir_pid, tag} | opts])
      {tag, tid}
    end)
  end
end
