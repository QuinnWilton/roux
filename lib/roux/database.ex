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
  def register_entity(%__MODULE__{entity_registry: reg}, module)
      when is_atom(module) do
    case :ets.lookup(reg, module) do
      [{^module, _tid}] ->
        :ok

      [] ->
        tid = :ets.new(module, [:set, :public, write_concurrency: true])

        case :ets.insert_new(reg, {module, tid}) do
          true ->
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
  def intern_table(%__MODULE__{intern_registry: reg}, name)
      when is_atom(name) do
    case :ets.lookup(reg, name) do
      [{^name, %Intern{} = table}] ->
        table

      [] ->
        table = Intern.new(name)

        case :ets.insert_new(reg, {name, table}) do
          true ->
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

  # -- Private --

  defp find_table_owner(sup_pid) do
    sup_pid
    |> Elixir.Supervisor.which_children()
    |> Enum.find_value(fn
      {Roux.Database.TableOwner, pid, :worker, _} -> pid
      _ -> nil
    end)
  end
end
