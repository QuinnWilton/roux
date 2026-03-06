defmodule Roux.GCTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.{Database, Entity, GC, Memo, Revision}
  alias Roux.Memo.Entry

  @sample Roux.Test.SampleEntity

  setup do
    db = Database.new()
    Database.register_entity(db, @sample)

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    %{db: db}
  end

  # -- Helpers ----------------------------------------------------------------

  defp make_entry(opts) do
    %Entry{
      value: Keyword.get(opts, :value, :result),
      hash: :erlang.phash2(Keyword.get(opts, :value, :result)),
      changed_at: Keyword.get(opts, :changed_at, 1),
      verified_at: Keyword.get(opts, :verified_at, 1),
      dependencies: Keyword.get(opts, :dependencies, []),
      durability: Keyword.get(opts, :durability, :low),
      output_entities: Keyword.get(opts, :output_entities, [])
    }
  end

  defp create_entity(db, name) do
    Entity.create(db, @sample, %{name: name, body: nil, return_type: nil}, 1)
  end

  # -- sweep_query/3 tests ----------------------------------------------------

  describe "sweep_query/3" do
    test "increments refcount for new entities", %{db: db} do
      id = create_entity(db, :foo)
      assert Entity.refcount(db, @sample, id) == 0

      GC.sweep_query(db, {:q, :k}, old: [], new: [{@sample, id}])

      assert Entity.refcount(db, @sample, id) == 1
    end

    test "decrements refcount for removed entities", %{db: db} do
      id = create_entity(db, :foo)
      Entity.increment_refcount(db, @sample, id)
      assert Entity.refcount(db, @sample, id) == 1

      GC.sweep_query(db, {:q, :k}, old: [{@sample, id}], new: [])

      assert Entity.refcount(db, @sample, id) == 0
    end

    test "no-op for unchanged entities", %{db: db} do
      id = create_entity(db, :foo)
      Entity.increment_refcount(db, @sample, id)

      GC.sweep_query(db, {:q, :k}, old: [{@sample, id}], new: [{@sample, id}])

      assert Entity.refcount(db, @sample, id) == 1
    end

    test "mixed add and remove diffs correctly", %{db: db} do
      id1 = create_entity(db, :a)
      id2 = create_entity(db, :b)
      id3 = create_entity(db, :c)

      # id1 and id2 are in old set with refcount 1 each.
      Entity.increment_refcount(db, @sample, id1)
      Entity.increment_refcount(db, @sample, id2)

      # New set keeps id2, drops id1, adds id3.
      GC.sweep_query(db, {:q, :k},
        old: [{@sample, id1}, {@sample, id2}],
        new: [{@sample, id2}, {@sample, id3}]
      )

      assert Entity.refcount(db, @sample, id1) == 0
      assert Entity.refcount(db, @sample, id2) == 1
      assert Entity.refcount(db, @sample, id3) == 1
    end

    test "handles missing entity without crash", %{db: db} do
      id = create_entity(db, :foo)
      Entity.increment_refcount(db, @sample, id)

      # Delete the entity before sweep_query.
      Entity.delete(db, @sample, id)

      # Should not crash — rescues the ArgumentError.
      assert GC.sweep_query(db, {:q, :k}, old: [{@sample, id}], new: []) == :ok
    end
  end

  # -- sweep/1 tests ----------------------------------------------------------

  describe "sweep/1" do
    test "deletes zero-refcount entities", %{db: db} do
      id = create_entity(db, :dead)
      assert Entity.refcount(db, @sample, id) == 0

      result = GC.sweep(db)

      assert result.entities_removed == 1
      assert Entity.get_fields(db, @sample, id) == :error
    end

    test "preserves live entities (refcount > 0)", %{db: db} do
      id = create_entity(db, :alive)
      Entity.increment_refcount(db, @sample, id)

      result = GC.sweep(db)

      assert result.entities_removed == 0
      assert {:ok, _} = Entity.get_fields(db, @sample, id)
    end

    test "returns correct stats", %{db: db} do
      _dead1 = create_entity(db, :dead1)
      _dead2 = create_entity(db, :dead2)
      alive = create_entity(db, :alive)
      Entity.increment_refcount(db, @sample, alive)

      # Refcounts: dead1=0, dead2=0, alive=1.
      result = GC.sweep(db)

      assert result.entities_removed == 2
      assert result.memo_entries_removed == 0
      assert is_integer(result.duration_us)
    end

    test "deletes orphaned memo entries", %{db: db} do
      # Set up: input A exists, query B depends on A.
      input_key = {:input, :source, :a}
      query_key = {:q, :b}

      Memo.put(db, input_key, make_entry(value: :a_val))
      Memo.put(db, query_key, make_entry(dependencies: [input_key]))

      # Delete the input — now query B is orphaned.
      Memo.delete(db, input_key)

      result = GC.sweep(db)

      assert result.memo_entries_removed == 1
      assert Memo.get(db, query_key) == :miss
    end

    test "cascades orphan deletion", %{db: db} do
      # Chain: A → B → C (deleted).
      key_c = {:input, :source, :c}
      key_b = {:q, :b}
      key_a = {:q, :a}

      Memo.put(db, key_c, make_entry(value: :c_val))
      Memo.put(db, key_b, make_entry(dependencies: [key_c]))
      Memo.put(db, key_a, make_entry(dependencies: [key_b]))

      # Delete C — B becomes orphaned, then A becomes orphaned.
      Memo.delete(db, key_c)

      result = GC.sweep(db)

      assert result.memo_entries_removed == 2
      assert Memo.get(db, key_b) == :miss
      assert Memo.get(db, key_a) == :miss
    end

    test "does not delete entries with all deps present", %{db: db} do
      input_key = {:input, :source, :x}
      query_key = {:q, :y}

      Memo.put(db, input_key, make_entry(value: :x_val))
      Memo.put(db, query_key, make_entry(dependencies: [input_key]))

      result = GC.sweep(db)

      assert result.memo_entries_removed == 0
      assert {:ok, _} = Memo.get(db, query_key)
    end

    test "does not delete entries with empty dependencies", %{db: db} do
      # Input entries have no dependencies — they should never be orphaned.
      input_key = {:input, :source, :x}
      Memo.put(db, input_key, make_entry(value: :x_val))

      result = GC.sweep(db)

      assert result.memo_entries_removed == 0
      assert {:ok, _} = Memo.get(db, input_key)
    end

    test "with no work returns zero stats", %{db: db} do
      result = GC.sweep(db)

      assert result.entities_removed == 0
      assert result.memo_entries_removed == 0
    end

    test "emits telemetry event", %{db: db} do
      test_pid = self()
      event = [:roux, :gc, :sweep]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.forward_telemetry/4,
        test_pid
      )

      _dead = create_entity(db, :dead)

      GC.sweep(db)

      assert_received {:telemetry, ^event, measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.entities_removed == 1
      assert measurements.memo_entries_removed == 0
      assert is_integer(metadata.revision)

      :telemetry.detach(handler_id)
    end
  end

  @doc false
  def forward_telemetry(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  # -- mark_input_removed/3 tests ---------------------------------------------

  describe "mark_input_removed/3" do
    test "deletes memo entry for input", %{db: db} do
      input_key = {:input, :source, :a}
      Memo.put(db, input_key, make_entry(value: :a_val))

      GC.mark_input_removed(db, :source, :a)

      assert Memo.get(db, input_key) == :miss
    end

    test "advances revision", %{db: db} do
      input_key = {:input, :source, :a}
      Memo.put(db, input_key, make_entry(value: :a_val, durability: :low))

      rev_before = Revision.current(db.revision)
      GC.mark_input_removed(db, :source, :a)
      rev_after = Revision.current(db.revision)

      assert rev_after > rev_before
    end

    test "no-op for missing input", %{db: db} do
      rev_before = Revision.current(db.revision)

      GC.mark_input_removed(db, :source, :nonexistent)

      assert Revision.current(db.revision) == rev_before
    end

    test "respects durability from memo entry", %{db: db} do
      input_key = {:input, :source, :a}
      Memo.put(db, input_key, make_entry(value: :a_val, durability: :high))

      GC.mark_input_removed(db, :source, :a)

      # Revision advanced at :high durability.
      assert Revision.last_changed(db.revision, :high) > 0
    end
  end

  # -- Property tests ---------------------------------------------------------

  describe "property tests" do
    property "after sweep, no entity with refcount == 0 remains" do
      check all(
              names <- uniq_list_of(atom(:alphanumeric), min_length: 1, max_length: 10),
              live_count <- integer(0..length(names))
            ) do
        db = Database.new()
        Database.register_entity(db, @sample)

        {live_names, _dead_names} = Enum.split(names, live_count)

        ids =
          Enum.map(names, fn name ->
            {name, create_entity(db, name)}
          end)

        # Set refcount > 0 for live entities.
        Enum.each(live_names, fn name ->
          {_, id} = List.keyfind!(ids, name, 0)
          Entity.increment_refcount(db, @sample, id)
        end)

        GC.sweep(db)

        # Verify: no zero-refcount entity remains.
        Enum.each(ids, fn {name, id} ->
          if name in live_names do
            assert {:ok, _} = Entity.get_fields(db, @sample, id)
            assert Entity.refcount(db, @sample, id) > 0
          else
            assert Entity.get_fields(db, @sample, id) == :error
          end
        end)

        Database.shutdown(db)
      end
    end

    property "sweep_query refcount tracking matches entity reference count" do
      check all(
              query_count <- integer(1..5),
              entity_names <- uniq_list_of(atom(:alphanumeric), min_length: 1, max_length: 5)
            ) do
        db = Database.new()
        Database.register_entity(db, @sample)

        ids =
          Map.new(entity_names, fn name ->
            {name, create_entity(db, name)}
          end)

        # Generate random output entity sets for each query.
        query_entities =
          for i <- 1..query_count do
            subset = Enum.take_random(entity_names, Enum.random(0..length(entity_names)))
            entities = Enum.map(subset, fn name -> {@sample, ids[name]} end)
            {i, entities}
          end

        # Simulate initial sweep_query for each query (old = []).
        Enum.each(query_entities, fn {i, entities} ->
          GC.sweep_query(db, {:q, i}, old: [], new: entities)
        end)

        # Verify refcounts match the number of queries referencing each entity.
        Enum.each(entity_names, fn name ->
          expected =
            Enum.count(query_entities, fn {_i, entities} ->
              {@sample, ids[name]} in entities
            end)

          assert Entity.refcount(db, @sample, ids[name]) == expected
        end)

        Database.shutdown(db)
      end
    end
  end
end
