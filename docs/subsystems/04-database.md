# Subsystem: Database

Module: `Roux.Database`

## Purpose

The central handle for all framework state. A database is a struct holding references to ETS tables, atomics counters, and configuration. It is the `db` parameter threaded through all query calls.

See decisions [D2](../decisions.md) (ETS from the start) and [D4](../decisions.md) (struct-based identity).

## Dependencies

- `Roux.Intern` — manages intern tables
- `Roux.Revision` — revision counter and durability tracking
- `Roux.Telemetry` — emits lifecycle events (reserved, not yet wired)

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
    intern_registry: :ets.tid(),
    entity_registry: :ets.tid(),
    supervisor: pid()
  }
end
```

The `intern_registry` and `entity_registry` fields are ETS tables that map names/modules to their respective intern tables or entity tids. This replaces the earlier design of in-struct maps (`intern_tables`, `entity_tables`) — ETS-backed registries support thread-safe lazy creation via the CAS pattern used throughout the framework, without requiring struct mutation.

## Public API

```elixir
@spec new(keyword()) :: t()
# Create a new database with all ETS tables and atomics initialized.
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
# Idempotent — concurrent calls with the same module are safe.

@spec intern_table(t(), name :: atom()) :: Roux.Intern.t()
# Get or create an intern table by name. Lazily created on first access.
# Thread-safe — concurrent calls with the same name return the same table.

@spec revision(t()) :: Roux.Revision.t()
# Access the revision tracker.
```

## Table ownership and crash recovery

See decision [D12](../decisions.md) for rationale.

ETS tables are owned by `Roux.Database.TableOwner`, a GenServer whose only job is to hold table ownership. A dedicated `Roux.Database.Heir` GenServer preserves tables across TableOwner crashes, making recovery transparent to callers.

### Process roles

**`Roux.Database.Heir`** — Starts first. Receives `ETS-TRANSFER` messages when TableOwner dies. Holds tables temporarily and gives them back to the new TableOwner on restart. Publishes its PID via `:persistent_term` keyed by `{Roux.Database.Heir, sup_pid}` so TableOwner can find it without passing PIDs through the supervisor spec. Cleans up the persistent_term entry on termination.

**`Roux.Database.TableOwner`** — Creates ETS tables (or reclaims them from Heir on restart). Owns all tables during normal operation. Looks up Heir PID from `:persistent_term` — the supervisor PID is stable across child restarts, making this safe.

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
  7. Revision counter is unaffected (lives in the struct, not ETS)

Heir crashes:
  1. Supervisor's :rest_for_one strategy restarts both Heir and TableOwner
  2. TableOwner creates fresh tables (cold restart)
  3. Database struct's refs become stale — this is the catastrophic case
  4. Caller must create a new database via Database.new/1
```

The key insight: **ETS table IDs (tids) are stable across ownership transfers.** When a table moves TableOwner → Heir → new TableOwner, the tid never changes. Every `Database` struct already handed out to callers still has valid refs. The crash is transparent.

### Why Revision lives in the struct, not in TableOwner

Atomics have no ownership transfer mechanism — there is no heir protocol for `:atomics.atomics_ref()`. If TableOwner created the Revision, it would reset to 0 on every TableOwner restart, even the non-catastrophic case. That creates a dangerous inconsistency: memo entries survive the crash (heir-protected tids are stable) with `verified_at`/`changed_at` stamps like 42 and 78, but the global counter resets to 0.

With Revision in the struct:
- **TableOwner crash**: tables survive via heir, Revision survives in struct — consistent.
- **Heir crash (catastrophic)**: tables are destroyed, struct is stale. Caller must call `Database.new/1`, which creates fresh tables *and* a fresh Revision at 0 — consistent.

### Heir implementation sketch

```elixir
defmodule Roux.Database.Heir do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def reclaim(heir_pid), do: GenServer.call(heir_pid, :reclaim)

  def whereis(sup_pid), do: :persistent_term.get({__MODULE__, sup_pid})

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
  def handle_call(:reclaim, {caller, _}, state) do
    for {_tag, table} <- state.tables do
      :ets.give_away(table, caller, :reclaimed)
    end
    {:reply, {:ok, state.tables}, %{state | tables: %{}}}
  end

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, state.sup_pid})
  end
end
```

### TableOwner init

```elixir
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

defp create_tables(heir_pid) do
  Map.new(@table_specs, fn {tag, opts} ->
    # ETS heir option is a 3-tuple: {:heir, pid, heir_data}.
    tid = :ets.new(tag, [{:heir, heir_pid, tag} | opts])
    {tag, tid}
  end)
end
```

### CAS pattern for lazy registration

Both `intern_table/2` and `register_entity/2` use create-first, CAS, cleanup-on-loss:

```elixir
# Create the resource optimistically
resource = create_resource()

case :ets.insert_new(registry, {key, resource}) do
  true -> resource
  false ->
    # Lost the race — destroy ours and use the winner's.
    destroy_resource(resource)
    [{^key, winner}] = :ets.lookup(registry, key)
    winner
end
```

This avoids sentinel values (like `:pending`) that would be visible to concurrent readers between CAS and update.

## Lifecycle

```
Database.new/1
  ├── Start supervisor (:rest_for_one strategy)
  ├── Start Heir under supervisor (first child)
  │   └── Publish PID via :persistent_term
  ├── Start TableOwner under supervisor (second child)
  │   ├── Read Heir PID from :persistent_term
  │   ├── Heir.reclaim/1 → {:ok, %{}} (empty, fresh start)
  │   ├── Create memo_table (ETS :set, read_concurrency: true, heir: heir_pid)
  │   ├── Create query_registry (ETS :set, heir: heir_pid)
  │   ├── Create input_registry (ETS :set, heir: heir_pid)
  │   ├── Create task_registry (ETS :set, write_concurrency: true, heir: heir_pid)
  │   ├── Create dedup_table (ETS :set, write_concurrency: true, heir: heir_pid)
  │   ├── Create intern_registry (ETS :set, heir: heir_pid)
  │   └── Create entity_registry (ETS :set, heir: heir_pid)
  ├── Initialize Roux.Revision (atomics, owned by the struct)
  └── Return %Database{} struct with all refs

TableOwner crash recovery:
  ├── Tables transfer to Heir automatically (ETS-TRANSFER)
  ├── Supervisor restarts TableOwner
  ├── TableOwner calls Heir.reclaim/1 → {:ok, tables}
  ├── Heir gives tables back via :ets.give_away/3
  ├── Database struct table refs remain valid (tids unchanged)
  └── Database struct Revision remains valid (atomics, not affected)

Database.shutdown/1
  ├── Stop supervisor (cascades to Heir and TableOwner)
  ├── All ETS tables destroyed automatically
  └── Database handle is now invalid
```

## Implementation notes

- ETS tables are unnamed (no `:named_table`) to support multiple databases. Store `tid()` references in the struct.
- The `intern_registry` and `entity_registry` ETS tables grow dynamically as new types are registered. Both use the CAS pattern for thread-safe lazy creation.
- The supervisor uses `:rest_for_one` strategy: if Heir crashes, TableOwner restarts too (tables are lost). If TableOwner crashes, Heir stays up to preserve tables.
- All ETS tables must be created with `{:heir, heir_pid, table_tag}` (a 3-tuple, not keyword syntax) where `table_tag` is an atom key used to identify the table during reclaim. These are a bounded set of framework-internal atoms, not user-facing.
- `Heir.reclaim/1` is a synchronous `GenServer.call`. This is safe because Heir is always started before TableOwner in the `:rest_for_one` order.
- After reclaim, Heir's state is empty — it holds no table refs until the next crash.
- Heir PID coordination uses `:persistent_term` keyed by `{Roux.Database.Heir, sup_pid}`. The supervisor PID is stable across child restarts, so TableOwner always finds the correct Heir.
- Revision lives in the Database struct, not in the process tree. Atomics have no ownership transfer mechanism, so heir-protecting them is impossible. See "Why Revision lives in the struct" above.

## Testing strategy

### Unit tests
- Create database, verify all tables exist with correct ETS options (public, read/write_concurrency)
- Shutdown database, verify tables are destroyed and supervisor stopped
- Register query, verify it appears in registry; re-registration overwrites
- Register input, verify it appears in registry with options as map
- Register entity, verify ETS table is created; verify idempotency
- Intern table: verify lazy creation, same name returns same table, different names yield different tables, interned table is functional
- Revision accessor returns the tracker; revision is shared across calls
- Create multiple databases, verify they are independent (tables and revisions)

### Integration tests
- Write data to memo table, kill TableOwner, verify data survives after recovery
- Verify Database struct refs remain valid after TableOwner crash (all 7 tables)
- Kill Heir, verify both processes restart and old tids are stale (catastrophic case)
- *(Deferred to Runtime)* Create database, register queries, execute queries, shutdown

### Concuerror tests
See decision [D11](../decisions.md). Deferred until needed.
- TableOwner crash during active ETS write → table either completes write or transfers cleanly
- Reclaim racing with ETS-TRANSFER messages → Heir returns all tables, none lost
