# Subsystem: Database

Module: `Roux.Database`

## Purpose

The central handle for all framework state. A database is a struct holding references to ETS tables, atomics counters, and configuration. It is the `db` parameter threaded through all query calls.

See decisions [D2](../decisions.md) (ETS from the start) and [D4](../decisions.md) (struct-based identity).

## Dependencies

- `Roux.Intern` — manages intern tables
- `Roux.Revision` — revision counter and durability tracking
- `Roux.Telemetry` — emits lifecycle events

## Key types

```elixir
defmodule Roux.Database do
  @type t :: %__MODULE__{
    memo_table: :ets.tid(),
    revision: Roux.Revision.t(),
    query_registry: :ets.tid(),
    input_registry: :ets.tid(),
    task_registry: :ets.tid(),
    dedup_table: :ets.tid(),
    intern_tables: %{atom() => Roux.Intern.t()},
    entity_tables: %{module() => :ets.tid()},
    supervisor: pid()
  }
end
```

## Public API

```elixir
@spec new(keyword()) :: t()
# Create a new database with all ETS tables and atomics initialized.
# Options:
#   :name — optional name for debugging (not used as ETS names)
# Starts a supervisor process that owns all ETS tables.

@spec shutdown(t()) :: :ok
# Destroy all ETS tables and stop the supervisor. The database handle
# becomes invalid after this call.

@spec register_query(t(), query_name :: atom(), query_def :: map()) :: :ok
# Register a derived query definition. Called during module compilation
# by the defquery macro, or manually.

@spec register_input(t(), input_name :: atom(), opts :: keyword()) :: :ok
# Register an input definition with its durability level.

@spec register_entity(t(), module()) :: :ok
# Register an entity type. Creates its ETS table for field storage.

@spec intern_table(t(), name :: atom()) :: Roux.Intern.t()
# Get or create an intern table by name. Lazily created on first access.

@spec revision(t()) :: Roux.Revision.t()
# Access the revision tracker.
```

## Table ownership and crash recovery

See decision [D12](../decisions.md) for rationale.

ETS tables are owned by `Roux.Database.TableOwner`, a GenServer whose only job is to hold table ownership. A dedicated `Roux.Database.Heir` GenServer preserves tables across TableOwner crashes, making recovery transparent to callers.

### Process roles

**`Roux.Database.Heir`** — Starts first. Receives `ETS-TRANSFER` messages when TableOwner dies. Holds tables temporarily and gives them back to the new TableOwner on restart. Does nothing else.

**`Roux.Database.TableOwner`** — Creates ETS tables (or reclaims them from Heir on restart). Owns all tables during normal operation. Does nothing else.

### Crash recovery protocol

```
Normal operation:
  Heir (idle) ← heir option on all tables
  TableOwner (owns all tables)

TableOwner crashes:
  1. ETS transfers all tables to Heir via ETS-TRANSFER messages
  2. Heir stores table refs in its state
  3. Supervisor restarts TableOwner
  4. New TableOwner calls Heir.reclaim/1 in its init/1
  5. Heir calls :ets.give_away/3 for each table back to TableOwner
  6. Database struct's table refs remain valid (tids are stable across transfers)

Heir crashes:
  1. Supervisor's :rest_for_one strategy restarts both Heir and TableOwner
  2. TableOwner creates fresh tables (cold restart)
  3. Database struct's refs become stale — this is the catastrophic case
```

The key insight: **ETS table IDs (tids) are stable across ownership transfers.** When a table moves TableOwner → Heir → new TableOwner, the tid never changes. Every `Database` struct already handed out to callers still has valid refs. The crash is transparent.

### Heir implementation sketch

```elixir
defmodule Roux.Database.Heir do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def reclaim(heir_pid), do: GenServer.call(heir_pid, :reclaim)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_info({:"ETS-TRANSFER", table, _from, name}, state) do
    {:noreply, Map.put(state, name, table)}
  end

  @impl true
  def handle_call(:reclaim, {caller, _}, state) do
    for {_name, table} <- state do
      :ets.give_away(table, caller, nil)
    end
    {:reply, {:ok, state}, %{}}
  end
end
```

### TableOwner init

```elixir
def init(opts) do
  heir_pid = Keyword.fetch!(opts, :heir)

  tables =
    case Heir.reclaim(heir_pid) do
      {:ok, tables} when tables != %{} -> tables
      _ -> create_tables(heir_pid)
    end

  {:ok, %{tables: tables, heir: heir_pid}}
end

defp create_tables(heir_pid) do
  %{
    memo: :ets.new(:memo, [:set, :public, read_concurrency: true,
                            heir: {heir_pid, :memo}]),
    query_registry: :ets.new(:query_reg, [:set, :public,
                                           heir: {heir_pid, :query_registry}]),
    # ... etc for all tables
  }
end
```

## Lifecycle

```
Database.new/1
  ├── Start supervisor (:rest_for_one strategy)
  ├── Start Heir under supervisor (first child)
  ├── Start TableOwner under supervisor (second child, receives heir pid)
  │   ├── Heir.reclaim/1 → {:ok, %{}} (empty, fresh start)
  │   ├── Create memo_table (ETS :set, read_concurrency: true, heir: heir_pid)
  │   ├── Create query_registry (ETS :set, heir: heir_pid)
  │   ├── Create input_registry (ETS :set, heir: heir_pid)
  │   ├── Create task_registry (ETS :set, write_concurrency: true, heir: heir_pid)
  │   ├── Create dedup_table (ETS :set, write_concurrency: true, heir: heir_pid)
  │   └── Initialize Roux.Revision
  └── Return %Database{} struct with all refs

TableOwner crash recovery:
  ├── Tables transfer to Heir automatically (ETS-TRANSFER)
  ├── Supervisor restarts TableOwner
  ├── TableOwner calls Heir.reclaim/1 → {:ok, tables}
  ├── Heir gives tables back via :ets.give_away/3
  └── Database struct refs remain valid (tids unchanged)

Database.shutdown/1
  ├── Stop supervisor (cascades to Heir and TableOwner)
  ├── All ETS tables destroyed automatically
  └── Database handle is now invalid
```

## Implementation notes

- ETS tables are unnamed (no atoms) to support multiple databases. Store `tid()` references in the struct.
- The `intern_tables` and `entity_tables` maps grow dynamically as new types are registered. These maps live in the struct, which is immutable — but since registration only happens at startup (module compilation), this is fine. If dynamic registration is needed later, these maps can move to ETS.
- The supervisor uses `:rest_for_one` strategy: if Heir crashes, TableOwner restarts too (tables are lost). If TableOwner crashes, Heir stays up to preserve tables.
- All ETS tables must be created with `heir: {heir_pid, table_name}` where `table_name` is an atom key used to identify the table during reclaim. These are a bounded set of framework-internal atoms, not user-facing.
- `Heir.reclaim/1` is a synchronous `GenServer.call`. This is safe because Heir is always started before TableOwner in the `:rest_for_one` order.
- After reclaim, Heir's state is empty — it holds no table refs until the next crash.

## Testing strategy

### Unit tests
- Create database, verify all tables exist
- Shutdown database, verify tables are destroyed
- Register query, verify it appears in registry
- Register input, verify it appears in registry
- Create multiple databases, verify they are independent

### Integration tests
- Create database, register queries, execute queries, shutdown
- Table owner crash recovery: kill TableOwner, verify tables survive and are reclaimed
- Verify Database struct refs remain valid after TableOwner crash
- Heir crash: kill Heir, verify both processes restart and tables are recreated
- Write data to memo table, kill TableOwner, verify data survives after recovery

### Concuerror tests
See decision [D11](../decisions.md).
- TableOwner crash during active ETS write → table either completes write or transfers cleanly
- Reclaim racing with ETS-TRANSFER messages → Heir returns all tables, none lost
