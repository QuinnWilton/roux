defmodule Roux.QueryLog do
  @moduledoc """
  Records which queries of a database executed, were served from the
  memo table, or came back unchanged (early cutoff): what an edit made
  a graph recompute, for tests that assert the exact recompute set and
  for harnesses that report it.

      log = Roux.QueryLog.start(db)
      Roux.Input.set(db, :source, "a.ex", "changed")
      MyQueries.compile(db, "a.ex")
      assert Roux.QueryLog.executions(log, :parse) == ["a.ex"]
      assert Roux.QueryLog.cutoffs(log, :parse) == ["a.ex"]
      Roux.QueryLog.stop(log)

  ## One database

  A log started for a database records only that database's events
  (the `database:` metadata every event carries, `Roux.Database.id/1`),
  so tests running side by side in one VM each see their own queries.
  `start(:all)` records every database's: for a harness that drives
  code which opens its database itself, such as a Mix compiler.

  ## Lifetime

  The events land in a public ETS table owned by a process of the
  log's own, not linked to the caller: a test can `stop/1` it from an
  `on_exit` callback, after the test process has exited. The handler
  the log attaches is VM-global until `stop/1` detaches it.
  """

  alias Roux.Database

  @enforce_keys [:handler, :table, :owner, :ref, :database]
  defstruct [:handler, :table, :owner, :ref, :database]

  @typedoc "A running log; see `start/1`."
  @type t :: %__MODULE__{
          handler: term(),
          table: :ets.tid(),
          owner: pid(),
          ref: reference(),
          database: Database.id() | :all
        }

  @typedoc "What happened to a query key: it executed, was served, or cut off."
  @type kind :: :execution | :hit | :cutoff

  @events [
    [:roux, :query, :start],
    [:roux, :cache, :hit],
    [:roux, :cache, :early_cutoff]
  ]

  @doc """
  Starts a log of `db`'s queries, or of every database's with `:all`.
  """
  @spec start(Database.t() | :all) :: t()
  def start(db_or_all) do
    database =
      case db_or_all do
        :all -> :all
        %Database{} = db -> Database.id(db)
      end

    {owner, ref, table} = start_owner()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(handler, @events, &__MODULE__.handle_event/4, {table, database})

    %__MODULE__{handler: handler, table: table, owner: owner, ref: ref, database: database}
  end

  # The table's owner: waits until told to stop, and takes the table
  # with it.
  defp start_owner do
    caller = self()
    ref = make_ref()

    owner =
      spawn(fn ->
        table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
        send(caller, {ref, table})

        receive do
          {^ref, :stop, from} -> send(from, {ref, :stopped})
        end
      end)

    receive do
      {^ref, table} -> {owner, ref, table}
    end
  end

  @doc false
  @spec handle_event([atom()], map(), map(), {:ets.tid(), Database.id() | :all}) :: :ok
  def handle_event(event, _measurements, metadata, {table, database}) do
    if database == :all or Map.get(metadata, :database) == database do
      :ets.insert(table, {{kind(event), metadata.query_name, metadata.key}})
    end

    :ok
  end

  defp kind([:roux, :query, :start]), do: :execution
  defp kind([:roux, :cache, :hit]), do: :hit
  defp kind([:roux, :cache, :early_cutoff]), do: :cutoff

  @doc "The keys of `query_name` that executed, sorted."
  @spec executions(t(), atom()) :: [term()]
  def executions(%__MODULE__{} = log, query_name), do: keys(log, :execution, query_name)

  @doc "The keys of `query_name` served from the memo table without executing, sorted."
  @spec hits(t(), atom()) :: [term()]
  def hits(%__MODULE__{} = log, query_name), do: keys(log, :hit, query_name)

  @doc "The keys of `query_name` that executed and came back unchanged, sorted."
  @spec cutoffs(t(), atom()) :: [term()]
  def cutoffs(%__MODULE__{} = log, query_name), do: keys(log, :cutoff, query_name)

  @doc """
  Every query that `kind` happened to, as `%{query_name => keys}`, each
  key list sorted: the whole window, for a harness that reports it.
  """
  @spec by_query(t(), kind()) :: %{optional(atom()) => [term()]}
  def by_query(%__MODULE__{table: table}, kind)
      when kind in [:execution, :hit, :cutoff] do
    table
    |> :ets.match({{kind, :"$1", :"$2"}})
    |> Enum.group_by(fn [name, _key] -> name end, fn [_name, key] -> key end)
    |> Map.new(fn {name, keys} -> {name, Enum.sort(keys)} end)
  end

  defp keys(%__MODULE__{table: table}, kind, query_name) when is_atom(query_name) do
    table
    |> :ets.match({{kind, query_name, :"$1"}})
    |> Enum.map(fn [key] -> key end)
    |> Enum.sort()
  end

  @doc "Forgets everything recorded so far: the start of a new window."
  @spec reset(t()) :: :ok
  def reset(%__MODULE__{table: table}) do
    :ets.delete_all_objects(table)
    :ok
  end

  @doc """
  Detaches the log's handler and deletes its table. Safe to call from
  any process, and more than once.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{handler: handler, owner: owner, ref: ref}) do
    _ = :telemetry.detach(handler)
    monitor = Process.monitor(owner)
    send(owner, {ref, :stop, self()})

    receive do
      {^ref, :stopped} -> :ok
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    end

    Process.demonitor(monitor, [:flush])
    :ok
  end
end
