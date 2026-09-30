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

  alias Roux.{Blob, Dependencies, Intern, Revision}
  alias Roux.Database.{Supervisor, TableOwner}

  @type t :: %__MODULE__{
          memo_table: :ets.tid(),
          revision: Revision.t(),
          query_registry: :ets.tid(),
          input_registry: :ets.tid(),
          task_registry: :ets.tid(),
          dedup_table: :ets.tid(),
          dedup_waiters: :ets.tid(),
          intern_registry: :ets.tid(),
          entity_registry: :ets.tid(),
          table_owner: pid(),
          supervisor: pid(),
          blob: Blob.t() | nil,
          writes: :atomics.atomics_ref() | nil,
          dependencies: Dependencies.t() | nil
        }

  @enforce_keys [
    :memo_table,
    :revision,
    :query_registry,
    :input_registry,
    :task_registry,
    :dedup_table,
    :dedup_waiters,
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
    :dedup_waiters,
    :intern_registry,
    :entity_registry,
    :table_owner,
    :supervisor,
    blob: nil,
    writes: nil,
    dependencies: nil
  ]

  @doc """
  Creates a new database with all ETS tables and atomics initialized.

  Starts a supervisor that owns all ETS tables via the Heir/TableOwner
  protocol. The returned struct holds stable references to those tables.

  ## Options

    * `:blob` — a `Roux.Blob` store: where a manifest keeps the values of
      `store: :blob` queries and the database reads them back, and where
      code versions are kept across VMs (`Roux.Query`).
    * `:reverse_dependencies` — defaults to false. Track reverse edges to
      skip validation of unaffected queries. Input writes mark transitive
      readers; affected queries still validate in dependency order. Adds
      memory and write work. Registered entity types disable the shortcut.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, blob: nil, reverse_dependencies: false)

    {:ok, sup_pid} = Supervisor.start_link(reverse_dependencies: opts[:reverse_dependencies])
    table_owner_pid = find_table_owner(sup_pid)
    tables = TableOwner.get_tables(table_owner_pid)

    %__MODULE__{
      memo_table: Map.fetch!(tables, :memo),
      revision: Revision.new(track_unknown: opts[:reverse_dependencies]),
      query_registry: Map.fetch!(tables, :query_registry),
      input_registry: Map.fetch!(tables, :input_registry),
      task_registry: Map.fetch!(tables, :task_registry),
      dedup_table: Map.fetch!(tables, :dedup_table),
      dedup_waiters: Map.fetch!(tables, :dedup_waiters),
      intern_registry: Map.fetch!(tables, :intern_registry),
      entity_registry: Map.fetch!(tables, :entity_registry),
      table_owner: table_owner_pid,
      supervisor: sup_pid,
      blob: Keyword.fetch!(opts, :blob),
      writes: :atomics.new(1, signed: false),
      dependencies: if(opts[:reverse_dependencies], do: Dependencies.new(tables))
    }
  end

  @doc """
  How many entries this database's queries have written so far
  (`note_write/1`): a session compares it to tell whether a run
  computed anything its manifest does not hold.
  """
  @spec writes(t()) :: non_neg_integer()
  def writes(%__MODULE__{writes: nil}), do: 0
  def writes(%__MODULE__{writes: writes}), do: :atomics.get(writes, 1)

  @doc false
  # Counts an entry a query wrote (`Roux.Runtime`).
  @spec note_write(t()) :: :ok
  def note_write(%__MODULE__{writes: nil}), do: :ok
  def note_write(%__MODULE__{writes: writes}), do: :atomics.add(writes, 1, 1)

  @typedoc "What tells a database apart from the others in the VM; see `id/1`."
  @type id :: :ets.tid()

  @doc """
  What tells this database apart from the others in the VM: its memo
  table, which no other database shares and which a
  `Roux.Database.TableOwner` restart keeps (see `Roux.Database.Heir`).
  Telemetry events carry it as `database:` metadata (`Roux.Telemetry`).
  """
  @spec id(t()) :: id()
  def id(%__MODULE__{memo_table: memo}), do: memo

  @doc """
  Destroys all ETS tables and stops the supervisor.

  The database handle becomes invalid after this call.
  """
  @spec shutdown(t()) :: :ok
  def shutdown(%__MODULE__{supervisor: sup_pid}) do
    Elixir.Supervisor.stop(sup_pid)
  end

  @doc """
  Registers a derived query definition: at least its `:module` and
  `:function`, and optionally its `:code_version`, `:store` and
  `:transient` (`Roux.Query`).

  Idempotent — re-registering the same name overwrites the previous
  definition. Registering a query again under another code version makes
  every entry of the query stale, and advances the revision at `:high`
  so that no durability check skips the entries that read them.
  """
  @spec register_query(t(), atom(), map()) :: :ok
  def register_query(%__MODULE__{query_registry: reg, revision: revision} = db, name, definition)
      when is_atom(name) and is_map(definition) do
    version = Map.get(definition, :code_version)

    case :ets.lookup(reg, name) do
      [{^name, %{} = old}] ->
        if Map.get(old, :code_version) != version do
          Dependencies.mutate(db, :all, fn ->
            :ets.insert(reg, {name, definition})
            Revision.advance(revision, :high)
          end)
        else
          :ets.insert(reg, {name, definition})
        end

      [] ->
        # Ad-hoc execute/4 calls may have cached this query before registration.
        Dependencies.mutate(db, :all, fn -> :ets.insert(reg, {name, definition}) end)
    end

    :ok
  end

  @doc """
  The code version a query is registered with (`register_query/3`): nil
  for a query registered without one, or not registered at all.
  """
  @spec code_version(t(), atom()) :: binary() | nil
  def code_version(%__MODULE__{query_registry: reg}, name) when is_atom(name) do
    case :ets.lookup(reg, name) do
      [{^name, %{} = definition}] -> Map.get(definition, :code_version)
      _ -> nil
    end
  end

  @doc "What a query is registered with (`register_query/3`), or nil."
  @spec query_definition(t(), atom()) :: map() | nil
  def query_definition(%__MODULE__{query_registry: reg}, name) when is_atom(name) do
    case :ets.lookup(reg, name) do
      [{^name, %{} = definition}] -> definition
      _ -> nil
    end
  end

  @doc "Whether a derived query of this name is registered."
  @spec query_registered?(t(), atom()) :: boolean()
  def query_registered?(%__MODULE__{query_registry: reg}, name) when is_atom(name) do
    match?([{^name, %{}}], :ets.lookup(reg, name))
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
  The durability an input was registered with (`register_input/3`),
  `:medium` when it names none. Raises `ArgumentError` for an input that
  is not registered.
  """
  @spec input_durability(t(), atom()) :: Revision.durability()
  def input_durability(%__MODULE__{input_registry: reg}, name) when is_atom(name) do
    case :ets.lookup(reg, name) do
      [{^name, opts}] -> Map.get(opts, :durability, :medium)
      [] -> raise ArgumentError, "input #{inspect(name)} is not registered"
    end
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
    # A database assembled without a supervisor (the Concuerror fixtures)
    # names the calling process as owner: the table is already where it
    # belongs, and there is no heir to look up. `give_away` to self is a
    # badarg in any case.
    if owner_pid != self() do
      heir_pid = Roux.Database.Heir.whereis(sup_pid)
      :ets.setopts(tid, {:heir, heir_pid, {:dynamic, tid}})
      :ets.give_away(tid, owner_pid, :dynamic)
    end

    :ok
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
