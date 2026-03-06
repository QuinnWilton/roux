defmodule Roux.Database do
  @moduledoc """
  Central handle for all framework state.

  A database is a struct holding references to ETS tables, atomics counters,
  and the supervisor that owns those tables. It is the `db` parameter threaded
  through all query calls.

  ETS tables survive `TableOwner` crashes transparently — table IDs are stable
  across ownership transfers, so existing `Database` structs remain valid. See
  `Roux.Database.Heir` for the crash recovery protocol.

  ## Lifecycle

      db = Roux.Database.new()
      # ... register queries, inputs, entities ...
      # ... execute queries ...
      Roux.Database.shutdown(db)

  """

  alias Roux.Database.{Supervisor, TableOwner}
  alias Roux.{Intern, Revision}

  @type t :: %__MODULE__{
          memo_table: :ets.tid(),
          revision: Revision.t(),
          query_registry: :ets.tid(),
          input_registry: :ets.tid(),
          task_registry: :ets.tid(),
          dedup_table: :ets.tid(),
          intern_registry: :ets.tid(),
          entity_registry: :ets.tid(),
          table_owner: pid(),
          supervisor: pid()
        }

  @enforce_keys [
    :memo_table,
    :revision,
    :query_registry,
    :input_registry,
    :task_registry,
    :dedup_table,
    :intern_registry,
    :entity_registry,
    :table_owner,
    :supervisor
  ]

  defstruct [
    :memo_table,
    :revision,
    :query_registry,
    :input_registry,
    :task_registry,
    :dedup_table,
    :intern_registry,
    :entity_registry,
    :table_owner,
    :supervisor
  ]

  @doc """
  Creates a new database with all ETS tables and atomics initialized.

  Starts a supervisor that owns all ETS tables via the Heir/TableOwner
  protocol. The returned struct holds stable references to those tables.
  """
  @spec new(keyword()) :: t()
  def new(_opts \\ []) do
    {:ok, sup_pid} = Supervisor.start_link()
    table_owner_pid = find_table_owner(sup_pid)
    tables = TableOwner.get_tables(table_owner_pid)

    %__MODULE__{
      memo_table: Map.fetch!(tables, :memo),
      revision: Revision.new(),
      query_registry: Map.fetch!(tables, :query_registry),
      input_registry: Map.fetch!(tables, :input_registry),
      task_registry: Map.fetch!(tables, :task_registry),
      dedup_table: Map.fetch!(tables, :dedup_table),
      intern_registry: Map.fetch!(tables, :intern_registry),
      entity_registry: Map.fetch!(tables, :entity_registry),
      table_owner: table_owner_pid,
      supervisor: sup_pid
    }
  end

  @doc """
  Destroys all ETS tables and stops the supervisor.

  The database handle becomes invalid after this call.
  """
  @spec shutdown(t()) :: :ok
  def shutdown(%__MODULE__{supervisor: sup_pid}) do
    Elixir.Supervisor.stop(sup_pid)
  end

  @doc """
  Registers a derived query definition.

  Called during module compilation by the `defquery` macro, or manually.
  Raises `ArgumentError` if a query with the same name is already registered.
  """
  @spec register_query(t(), atom(), map()) :: :ok
  def register_query(%__MODULE__{query_registry: reg}, name, definition)
      when is_atom(name) and is_map(definition) do
    case :ets.insert_new(reg, {name, definition}) do
      true -> :ok
      false -> raise ArgumentError, "query #{inspect(name)} is already registered"
    end
  end

  @doc """
  Registers an input definition with its options.

  Options typically include `:durability` (defaults to `:low`).
  """
  @spec register_input(t(), atom(), keyword()) :: :ok
  def register_input(%__MODULE__{input_registry: reg}, name, opts \\ [])
      when is_atom(name) do
    :ets.insert(reg, {name, Map.new(opts)})
    :ok
  end

  @doc """
  Registers an entity type, creating its ETS table for field storage.

  Idempotent — calling with the same module twice returns `:ok` without
  creating a second table.
  """
  @spec register_entity(t(), module()) :: :ok
  def register_entity(
        %__MODULE__{entity_registry: reg, table_owner: owner, supervisor: sup},
        module
      )
      when is_atom(module) do
    case :ets.lookup(reg, module) do
      [{^module, _tid}] ->
        :ok

      [] ->
        tid =
          :ets.new(module, [:set, :public, read_concurrency: true, write_concurrency: true])

        case :ets.insert_new(reg, {module, tid}) do
          true ->
            # Transfer ownership to TableOwner so the table survives
            # after the calling process (e.g. a query task) exits.
            give_away_table(tid, owner, sup)
            :ok

          false ->
            # Lost the CAS race — destroy our table and use the winner's.
            :ets.delete(tid)
            :ok
        end
    end
  end

  @doc """
  Gets or creates an intern table by name.

  Lazily created on first access. Thread-safe via ETS CAS — concurrent calls
  with the same name return the same `Roux.Intern.t()`.
  """
  @spec intern_table(t(), atom()) :: Intern.t()
  def intern_table(%__MODULE__{intern_registry: reg, table_owner: owner, supervisor: sup}, name)
      when is_atom(name) do
    case :ets.lookup(reg, name) do
      [{^name, %Intern{} = table}] ->
        table

      [] ->
        table = Intern.new(name)

        case :ets.insert_new(reg, {name, table}) do
          true ->
            # Transfer ownership to TableOwner so the tables survive
            # after the calling process (e.g. a query task) exits.
            give_away_table(table.forward, owner, sup)
            give_away_table(table.reverse, owner, sup)
            table

          false ->
            # Lost the CAS race — destroy our table and use the winner's.
            Intern.destroy(table)
            [{^name, winner}] = :ets.lookup(reg, name)
            winner
        end
    end
  end

  @doc """
  Returns the revision tracker for this database.
  """
  @spec revision(t()) :: Revision.t()
  def revision(%__MODULE__{revision: rev}), do: rev

  @doc """
  Returns all registered entity type modules.
  """
  @spec entity_types(t()) :: [module()]
  def entity_types(%__MODULE__{entity_registry: reg}) do
    reg
    |> :ets.tab2list()
    |> Enum.map(fn {module, _tid} -> module end)
  end

  @doc """
  Returns the names of all intern tables that have been created.
  """
  @spec intern_table_names(t()) :: [atom()]
  def intern_table_names(%__MODULE__{intern_registry: reg}) do
    reg
    |> :ets.tab2list()
    |> Enum.map(fn {name, _intern} -> name end)
  end

  @doc """
  Looks up a query by name in the registry and invokes it with the given key.

  Raises `ArgumentError` if the query is not registered.
  """
  @spec dispatch_query(t(), atom(), term()) :: term()
  def dispatch_query(%__MODULE__{query_registry: reg} = db, query_name, key)
      when is_atom(query_name) do
    case :ets.lookup(reg, query_name) do
      [{^query_name, %{module: mod, function: fun}}] ->
        apply(mod, fun, [db, key])

      [] ->
        raise ArgumentError, "query #{inspect(query_name)} is not registered"
    end
  end

  # -- Private --

  # Transfers ETS table ownership to the TableOwner process so the table
  # survives after the current (creating) process exits. Sets heir BEFORE
  # giving away to close the race window where TableOwner owns the table
  # but hasn't set heir yet.
  defp give_away_table(tid, owner_pid, sup_pid) do
    heir_pid = Roux.Database.Heir.whereis(sup_pid)
    :ets.setopts(tid, {:heir, heir_pid, {:dynamic, tid}})
    :ets.give_away(tid, owner_pid, :dynamic)
  end

  defp find_table_owner(sup_pid) do
    sup_pid
    |> Elixir.Supervisor.which_children()
    |> Enum.find_value(fn
      {Roux.Database.TableOwner, pid, :worker, _} -> pid
      _ -> nil
    end)
  end
end
