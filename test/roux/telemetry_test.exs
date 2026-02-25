defmodule Roux.TelemetryTest do
  use ExUnit.Case, async: true

  alias Roux.Telemetry

  # Module function handler to avoid telemetry's local function warning.
  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  setup do
    handler_id = make_ref()
    test_pid = self()

    %{handler_id: handler_id, test_pid: test_pid}
  end

  defp attach(handler_id, event, test_pid) do
    :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, test_pid)
  end

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
      attach(ctx.handler_id, [:roux, :test, :event], ctx.test_pid)

      Telemetry.event([:test, :event], %{count: 1}, %{label: "hello"})

      {measurements, metadata} = assert_event([:roux, :test, :event], [:count], [:label])
      assert measurements.count == 1
      assert metadata.label == "hello"
    end
  end

  describe "span/3" do
    test "emits start and stop events", ctx do
      attach(ctx.handler_id, [:roux, :test, :start], ctx.test_pid)
      attach(make_ref(), [:roux, :test, :stop], ctx.test_pid)

      result = Telemetry.span([:test], %{key: :a}, fn -> {:value, %{key: :a}} end)

      assert result == :value
      assert_event([:roux, :test, :start], [:system_time], [:key])
      assert_event([:roux, :test, :stop], [:duration], [:key])
    end
  end

  # -- Query lifecycle --

  describe "query_start/3" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :query, :start], ctx.test_pid)
      Telemetry.query_start(:parse, "foo.ex", 5)
      assert_event([:roux, :query, :start], [:system_time], [:query_name, :key, :revision])
    end
  end

  describe "query_stop/5" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :query, :stop], ctx.test_pid)
      Telemetry.query_stop(:parse, "foo.ex", 5, 1234, <<1, 2, 3>>)

      assert_event([:roux, :query, :stop], [:duration], [
        :query_name,
        :key,
        :revision,
        :result_hash
      ])
    end
  end

  describe "query_exception/6" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :query, :exception], ctx.test_pid)
      Telemetry.query_exception(:parse, "foo.ex", 5, 1234, :error, :badarg)

      assert_event([:roux, :query, :exception], [:duration], [
        :query_name,
        :key,
        :revision,
        :kind,
        :reason
      ])
    end
  end

  # -- Cache operations --

  describe "cache_hit/5" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :cache, :hit], ctx.test_pid)
      Telemetry.cache_hit(:parse, "foo.ex", 5, 3, 4)

      {_measurements, metadata} =
        assert_event([:roux, :cache, :hit], [], [
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

  describe "cache_miss/3" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :cache, :miss], ctx.test_pid)
      Telemetry.cache_miss(:parse, "foo.ex", 5)
      assert_event([:roux, :cache, :miss], [], [:query_name, :key, :revision])
    end
  end

  describe "early_cutoff/4" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :cache, :early_cutoff], ctx.test_pid)
      Telemetry.early_cutoff(:parse, "foo.ex", 5, 3)

      assert_event([:roux, :cache, :early_cutoff], [], [:query_name, :key, :revision, :changed_at])
    end
  end

  # -- Validation --

  describe "validation_start/3" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :validation, :start], ctx.test_pid)
      Telemetry.validation_start(:parse, "foo.ex", 5)
      assert_event([:roux, :validation, :start], [:system_time], [:query_name, :key, :revision])
    end
  end

  describe "validation_stop/5" do
    test "emits with correct shape for :valid", ctx do
      attach(ctx.handler_id, [:roux, :validation, :stop], ctx.test_pid)
      Telemetry.validation_stop(:parse, "foo.ex", 5, 1234, :valid)

      {_measurements, metadata} =
        assert_event([:roux, :validation, :stop], [:duration], [
          :query_name,
          :key,
          :revision,
          :result
        ])

      assert metadata.result == :valid
    end

    test "emits with correct shape for :stale", ctx do
      attach(ctx.handler_id, [:roux, :validation, :stop], ctx.test_pid)
      Telemetry.validation_stop(:parse, "foo.ex", 5, 1234, :stale)

      {_measurements, metadata} =
        assert_event([:roux, :validation, :stop], [:duration], [
          :query_name,
          :key,
          :revision,
          :result
        ])

      assert metadata.result == :stale
    end
  end

  describe "durability_skip/4" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :validation, :durability_skip], ctx.test_pid)
      Telemetry.durability_skip(:parse, "foo.ex", :high, 5)

      assert_event([:roux, :validation, :durability_skip], [], [
        :query_name,
        :key,
        :durability,
        :revision
      ])
    end
  end

  # -- Other operations --

  describe "input_set/4" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :input, :set], ctx.test_pid)
      Telemetry.input_set(:source_text, "foo.ex", 5, :low)
      assert_event([:roux, :input, :set], [], [:input_name, :key, :revision, :durability])
    end
  end

  describe "cycle_detected/3" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :cycle, :detected], ctx.test_pid)
      Telemetry.cycle_detected(:parse, "foo.ex", [{:parse, "foo.ex"}, {:resolve, "foo.ex"}])
      assert_event([:roux, :cycle, :detected], [], [:query_name, :key, :stack])
    end
  end

  describe "cancel_task/3" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :cancel, :task], ctx.test_pid)
      Telemetry.cancel_task(:parse, "foo.ex", :input_changed)
      assert_event([:roux, :cancel, :task], [], [:query_name, :key, :reason])
    end
  end

  describe "gc_sweep/3" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :gc, :sweep], ctx.test_pid)
      Telemetry.gc_sweep(5000, 42, 10)

      {measurements, _metadata} =
        assert_event([:roux, :gc, :sweep], [:duration, :entries_removed], [:revision])

      assert measurements.duration == 5000
      assert measurements.entries_removed == 42
    end
  end

  describe "intern_new/3" do
    test "emits with correct shape", ctx do
      attach(ctx.handler_id, [:roux, :intern, :new], ctx.test_pid)
      Telemetry.intern_new(:identifiers, 1, 24)
      assert_event([:roux, :intern, :new], [], [:table_name, :id, :value_size])
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
        :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, nil)
        :ok = :telemetry.detach(handler_id)
      end
    end
  end
end
