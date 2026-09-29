defmodule Roux.TelemetryTest do
  use ExUnit.Case, async: true

  alias Roux.Telemetry

  # Module function handler to avoid telemetry's local function warning.
  # Forwards the events `wanted?` accepts: the ones the test emitted.
  def handle_event(event, measurements, metadata, {pid, wanted?}) do
    if wanted?.(metadata), do: send(pid, {:telemetry, event, measurements, metadata})
  end

  # A database of the test's own: every event but the generic ones and
  # `[:roux, :intern, :new]` names its database, and other tests, run
  # beside this one, emit the same events for theirs.
  setup do
    %{test_pid: self(), database: make_ref()}
  end

  # Attaches a handler forwarding `event` to the test when `wanted?`
  # accepts its metadata (by default: it names the test's database),
  # detached when the test ends.
  defp attach(ctx, event, wanted? \\ nil) do
    database = ctx.database
    wanted? = wanted? || (&match?(%{database: ^database}, &1))
    handler_id = make_ref()

    :ok =
      :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, {ctx.test_pid, wanted?})

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # For the events whose names are this module's own.
  defp any(_metadata), do: true

  defp none(_metadata), do: false

  defp assert_event(event, measurements_keys, metadata_keys) do
    assert_received {:telemetry, ^event, measurements, metadata}

    for key <- measurements_keys,
        do: assert(Map.has_key?(measurements, key), "missing measurement: #{key}")

    for key <- metadata_keys, do: assert(Map.has_key?(metadata, key), "missing metadata: #{key}")
    {measurements, metadata}
  end

  # -- Generic API --

  describe "event/3" do
    test "emits a :telemetry event with [:roux | event_name] prefix", ctx do
      attach(ctx, [:roux, :test, :event], &any/1)

      Telemetry.event([:test, :event], %{count: 1}, %{label: "hello"})

      {measurements, metadata} = assert_event([:roux, :test, :event], [:count], [:label])
      assert measurements.count == 1
      assert metadata.label == "hello"
    end
  end

  describe "span/3" do
    test "emits start and stop events", ctx do
      attach(ctx, [:roux, :test, :start], &any/1)
      attach(ctx, [:roux, :test, :stop], &any/1)

      result = Telemetry.span([:test], %{key: :a}, fn -> {:value, %{key: :a}} end)

      assert result == :value
      assert_event([:roux, :test, :start], [:system_time], [:key])
      assert_event([:roux, :test, :stop], [:duration], [:key])
    end
  end

  # -- Query lifecycle --

  describe "query_start/4" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :query, :start])
      Telemetry.query_start(ctx.database, :parse, "foo.ex", 5)

      assert_event([:roux, :query, :start], [:system_time], [
        :database,
        :query_name,
        :key,
        :revision
      ])
    end
  end

  describe "query_stop/6" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :query, :stop])
      Telemetry.query_stop(ctx.database, :parse, "foo.ex", 5, 1234, <<1, 2, 3>>)

      assert_event([:roux, :query, :stop], [:duration], [
        :database,
        :query_name,
        :key,
        :revision,
        :result_hash
      ])
    end
  end

  describe "query_exception/7" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :query, :exception])
      Telemetry.query_exception(ctx.database, :parse, "foo.ex", 5, 1234, :error, :badarg)

      assert_event([:roux, :query, :exception], [:duration], [
        :database,
        :query_name,
        :key,
        :revision,
        :kind,
        :reason
      ])
    end
  end

  # -- Cache operations --

  describe "cache_hit/6" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :cache, :hit])
      Telemetry.cache_hit(ctx.database, :parse, "foo.ex", 5, 3, 4)

      {_measurements, metadata} =
        assert_event([:roux, :cache, :hit], [], [
          :database,
          :query_name,
          :key,
          :revision,
          :changed_at,
          :verified_at
        ])

      assert metadata.changed_at == 3
      assert metadata.verified_at == 4
    end
  end

  describe "cache_miss/4" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :cache, :miss])
      Telemetry.cache_miss(ctx.database, :parse, "foo.ex", 5)
      assert_event([:roux, :cache, :miss], [], [:database, :query_name, :key, :revision])
    end
  end

  describe "early_cutoff/5" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :cache, :early_cutoff])
      Telemetry.early_cutoff(ctx.database, :parse, "foo.ex", 5, 3)

      assert_event([:roux, :cache, :early_cutoff], [], [
        :database,
        :query_name,
        :key,
        :revision,
        :changed_at
      ])
    end
  end

  # -- Validation --

  describe "validation_start/4" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :validation, :start])
      Telemetry.validation_start(ctx.database, :parse, "foo.ex", 5)

      assert_event([:roux, :validation, :start], [:system_time], [
        :database,
        :query_name,
        :key,
        :revision
      ])
    end
  end

  describe "validation_stop/6" do
    test "emits with correct shape for :valid", ctx do
      attach(ctx, [:roux, :validation, :stop])
      Telemetry.validation_stop(ctx.database, :parse, "foo.ex", 5, 1234, :valid)

      {_measurements, metadata} =
        assert_event([:roux, :validation, :stop], [:duration], [
          :database,
          :query_name,
          :key,
          :revision,
          :result
        ])

      assert metadata.result == :valid
    end

    test "emits with correct shape for :stale", ctx do
      attach(ctx, [:roux, :validation, :stop])
      Telemetry.validation_stop(ctx.database, :parse, "foo.ex", 5, 1234, :stale)

      {_measurements, metadata} =
        assert_event([:roux, :validation, :stop], [:duration], [
          :database,
          :query_name,
          :key,
          :revision,
          :result
        ])

      assert metadata.result == :stale
    end
  end

  describe "durability_skip/5" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :validation, :durability_skip])
      Telemetry.durability_skip(ctx.database, :parse, "foo.ex", :high, 5)

      assert_event([:roux, :validation, :durability_skip], [], [
        :database,
        :query_name,
        :key,
        :durability,
        :revision
      ])
    end
  end

  # -- Other operations --

  describe "input_set/5" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :input, :set])
      Telemetry.input_set(ctx.database, :source_text, "foo.ex", 5, :low)

      assert_event([:roux, :input, :set], [], [
        :database,
        :input_name,
        :key,
        :revision,
        :durability
      ])
    end
  end

  describe "cycle_detected/4" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :cycle, :detected])

      Telemetry.cycle_detected(ctx.database, :parse, "foo.ex", [
        {:parse, "foo.ex"},
        {:resolve, "foo.ex"}
      ])

      assert_event([:roux, :cycle, :detected], [], [:database, :query_name, :key, :stack])
    end
  end

  describe "cancel_task/4" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :cancel, :task])
      Telemetry.cancel_task(ctx.database, :parse, "foo.ex", :input_changed)
      assert_event([:roux, :cancel, :task], [], [:database, :query_name, :key, :reason])
    end
  end

  describe "gc_sweep/5" do
    test "emits with correct shape", ctx do
      attach(ctx, [:roux, :gc, :sweep])
      Telemetry.gc_sweep(ctx.database, 5000, 42, 3, 10)

      {measurements, _metadata} =
        assert_event(
          [:roux, :gc, :sweep],
          [:duration, :memo_entries_removed, :entities_removed],
          [:database, :revision]
        )

      assert measurements.duration == 5000
      assert measurements.memo_entries_removed == 42
      assert measurements.entities_removed == 3
    end
  end

  describe "intern_new/3" do
    # No database to tell it by: a table name of the test's own.
    test "emits with correct shape", ctx do
      table = :"telemetry_test_#{System.unique_integer([:positive])}"
      attach(ctx, [:roux, :intern, :new], &match?(%{table_name: ^table}, &1))
      Telemetry.intern_new(table, 1, 24)
      assert_event([:roux, :intern, :new], [], [:table_name, :id, :value_size])
    end
  end

  # -- The database --

  describe "the database" do
    test "an event names the database it happened in", ctx do
      db = Roux.Database.new()
      other = Roux.Database.new()

      try do
        # The events of this test's databases: other tests' databases run
        # queries beside them.
        ids = [Roux.Database.id(db), Roux.Database.id(other)]
        attach(ctx, [:roux, :query, :start], &(Map.get(&1, :database) in ids))
        Roux.Runtime.execute(db, :telemetry_names_database, :k, fn _db, _key -> 1 end)

        assert_received {:telemetry, [:roux, :query, :start], _,
                         %{query_name: :telemetry_names_database, database: id}}

        assert id == Roux.Database.id(db)
        assert id != Roux.Database.id(other)
      after
        Roux.Database.shutdown(db)
        Roux.Database.shutdown(other)
      end
    end
  end

  # -- Event name completeness --

  describe "event schema" do
    @all_events [
      [:roux, :query, :start],
      [:roux, :query, :stop],
      [:roux, :query, :exception],
      [:roux, :cache, :hit],
      [:roux, :cache, :miss],
      [:roux, :cache, :early_cutoff],
      [:roux, :validation, :start],
      [:roux, :validation, :stop],
      [:roux, :validation, :durability_skip],
      [:roux, :input, :set],
      [:roux, :cycle, :detected],
      [:roux, :cancel, :task],
      [:roux, :gc, :sweep],
      [:roux, :intern, :new]
    ]

    test "all documented events are emittable" do
      for event <- @all_events do
        handler_id = make_ref()
        :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, {self(), &none/1})
        :ok = :telemetry.detach(handler_id)
      end
    end
  end
end
