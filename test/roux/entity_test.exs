defmodule Roux.EntityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.{Database, Entity, Intern}

  @sample Roux.Test.SampleEntity
  @multi Roux.Test.MultiIdEntity

  setup do
    db = Database.new()
    Database.register_entity(db, @sample)
    Database.register_entity(db, @multi)

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    %{db: db}
  end

  # -- Macro tests ------------------------------------------------------------

  describe "__using__ macro" do
    test "generates struct with all fields as enforced keys" do
      assert %@sample{name: :foo, body: :bar, return_type: :baz}

      assert_raise ArgumentError, fn ->
        struct!(@sample, name: :foo, body: :bar)
      end
    end

    test "__entity__(:identity_fields) returns identity fields in definition order" do
      assert @sample.__entity__(:identity_fields) == [:name]
    end

    test "__entity__(:tracked_fields) returns tracked fields in definition order" do
      assert @sample.__entity__(:tracked_fields) == [:body, :return_type]
    end

    test "__entity__(:all_fields) returns identity ++ tracked" do
      assert @sample.__entity__(:all_fields) == [:name, :body, :return_type]
    end

    test "multi-field identity fixture works correctly" do
      assert @multi.__entity__(:identity_fields) == [:module_name, :name]
      assert @multi.__entity__(:tracked_fields) == [:arity]
      assert @multi.__entity__(:all_fields) == [:module_name, :name, :arity]
    end
  end

  # -- create/4 tests ---------------------------------------------------------

  describe "create/4" do
    test "creates new entity and returns positive integer entity_id", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)
      assert is_integer(id) and id > 0
    end

    test "all fields readable after creation", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      assert Entity.field(db, @sample, id, :name) == :foo
      assert Entity.field(db, @sample, id, :body) == :bar
      assert Entity.field(db, @sample, id, :return_type) == :int
    end

    test "same identity returns same entity_id", %{db: db} do
      id1 = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)
      id2 = Entity.create(db, @sample, %{name: :foo, body: :baz, return_type: :int}, 2)

      assert id1 == id2
    end

    test "different identity returns different entity_id", %{db: db} do
      id1 = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)
      id2 = Entity.create(db, @sample, %{name: :qux, body: :bar, return_type: :int}, 1)

      assert id1 != id2
    end

    test "update: changed tracked field gets new changed_at", %{db: db} do
      Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      assert Entity.field_changed_at(db, @sample, 1, :body) == 1

      Entity.create(db, @sample, %{name: :foo, body: :new_bar, return_type: :int}, 5)

      assert Entity.field_changed_at(db, @sample, 1, :body) == 5
    end

    test "update: unchanged tracked field keeps original changed_at", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      assert Entity.field_changed_at(db, @sample, id, :return_type) == 1

      Entity.create(db, @sample, %{name: :foo, body: :new_bar, return_type: :int}, 5)

      # return_type unchanged, so changed_at stays at 1.
      assert Entity.field_changed_at(db, @sample, id, :return_type) == 1
    end

    test "multi-field identity works", %{db: db} do
      id =
        Entity.create(db, @multi, %{module_name: MyMod, name: :foo, arity: 2}, 1)

      assert Entity.field(db, @multi, id, :module_name) == MyMod
      assert Entity.field(db, @multi, id, :name) == :foo
      assert Entity.field(db, @multi, id, :arity) == 2
    end

    test "raises ArgumentError on unregistered entity type", %{db: db} do
      assert_raise ArgumentError, ~r/not registered/, fn ->
        Entity.create(db, UnregisteredEntity, %{name: :foo}, 1)
      end
    end

    test "raises KeyError on missing attrs", %{db: db} do
      assert_raise KeyError, fn ->
        Entity.create(db, @sample, %{name: :foo}, 1)
      end
    end
  end

  # -- field/4 and field_changed_at/4 tests -----------------------------------

  describe "field/4" do
    test "returns correct field value", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)
      assert Entity.field(db, @sample, id, :body) == :bar
    end

    test "raises on nonexistent entity_id", %{db: db} do
      assert_raise ArgumentError, ~r/not found/, fn ->
        Entity.field(db, @sample, 999, :body)
      end
    end

    test "raises on unknown field name", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      assert_raise ArgumentError, ~r/unknown field/, fn ->
        Entity.field(db, @sample, id, :nonexistent)
      end
    end
  end

  describe "field_changed_at/4" do
    test "returns correct changed_at revision", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 42)
      assert Entity.field_changed_at(db, @sample, id, :body) == 42
    end

    test "raises on nonexistent entity_id", %{db: db} do
      assert_raise ArgumentError, ~r/not found/, fn ->
        Entity.field_changed_at(db, @sample, 999, :body)
      end
    end

    test "raises on unknown field name", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      assert_raise ArgumentError, ~r/unknown field/, fn ->
        Entity.field_changed_at(db, @sample, id, :nonexistent)
      end
    end
  end

  # -- lookup/3 tests ---------------------------------------------------------

  describe "lookup/3" do
    test "returns {:ok, entity_id} for existing entity", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)
      assert Entity.lookup(db, @sample, {:foo}) == {:ok, id}
    end

    test "returns :error for nonexistent identity key", %{db: db} do
      assert Entity.lookup(db, @sample, {:nonexistent}) == :error
    end

    test "does not intern the identity key", %{db: db} do
      intern_table = Database.intern_table(db, @sample)
      size_before = Intern.size(intern_table)

      Entity.lookup(db, @sample, {:nonexistent})

      assert Intern.size(intern_table) == size_before
    end
  end

  # -- Refcount tests ---------------------------------------------------------

  describe "refcount operations" do
    test "initial refcount is 0", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)
      assert Entity.refcount(db, @sample, id) == 0
    end

    test "increment_refcount increments by 1", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      assert Entity.increment_refcount(db, @sample, id) == 1
      assert Entity.increment_refcount(db, @sample, id) == 2
      assert Entity.refcount(db, @sample, id) == 2
    end

    test "decrement_refcount decrements by 1", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      Entity.increment_refcount(db, @sample, id)
      Entity.increment_refcount(db, @sample, id)

      assert Entity.decrement_refcount(db, @sample, id) == 1
      assert Entity.refcount(db, @sample, id) == 1
    end

    test "decrement_refcount clamps at 0", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      assert Entity.decrement_refcount(db, @sample, id) == 0
      assert Entity.decrement_refcount(db, @sample, id) == 0
      assert Entity.refcount(db, @sample, id) == 0
    end

    test "alive? reflects refcount state", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      refute Entity.alive?(db, @sample, id)

      Entity.increment_refcount(db, @sample, id)
      assert Entity.alive?(db, @sample, id)

      Entity.decrement_refcount(db, @sample, id)
      refute Entity.alive?(db, @sample, id)
    end
  end

  # -- delete/3 and get_fields/3 tests ----------------------------------------

  describe "delete/3" do
    test "removes entity, get_fields returns :error after", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      assert {:ok, _} = Entity.get_fields(db, @sample, id)

      Entity.delete(db, @sample, id)

      assert Entity.get_fields(db, @sample, id) == :error
    end

    test "is no-op for nonexistent entity", %{db: db} do
      assert Entity.delete(db, @sample, 999) == :ok
    end
  end

  describe "get_fields/3" do
    test "returns {:ok, map} with all field entries", %{db: db} do
      id = Entity.create(db, @sample, %{name: :foo, body: :bar, return_type: :int}, 1)

      assert {:ok, fields} = Entity.get_fields(db, @sample, id)
      assert Map.keys(fields) |> Enum.sort() == [:body, :name, :return_type]

      assert fields.name.value == :foo
      assert fields.body.value == :bar
      assert fields.return_type.value == :int
      assert fields.name.changed_at == 1
    end

    test "returns :error for nonexistent entity", %{db: db} do
      assert Entity.get_fields(db, @sample, 999) == :error
    end
  end

  # -- Property tests ---------------------------------------------------------

  describe "property tests" do
    property "round-trip: create then read all fields returns the attrs values" do
      check all(
              name <- atom(:alphanumeric),
              body <- term(),
              return_type <- term(),
              revision <- positive_integer()
            ) do
        db = Database.new()
        Database.register_entity(db, @sample)

        attrs = %{name: name, body: body, return_type: return_type}
        id = Entity.create(db, @sample, attrs, revision)

        assert Entity.field(db, @sample, id, :name) == name
        assert Entity.field(db, @sample, id, :body) == body
        assert Entity.field(db, @sample, id, :return_type) == return_type

        Database.shutdown(db)
      end
    end

    property "identity uniqueness: distinct keys produce distinct entity_ids" do
      check all(names <- uniq_list_of(atom(:alphanumeric), min_length: 2, max_length: 10)) do
        db = Database.new()
        Database.register_entity(db, @sample)

        ids =
          Enum.map(names, fn name ->
            Entity.create(db, @sample, %{name: name, body: nil, return_type: nil}, 1)
          end)

        assert length(Enum.uniq(ids)) == length(names)

        Database.shutdown(db)
      end
    end

    property "field tracking: changed_at only advances for actually-changed fields" do
      check all(
              body1 <- term(),
              body2 <- term(),
              return_type <- term()
            ) do
        db = Database.new()
        Database.register_entity(db, @sample)

        id =
          Entity.create(
            db,
            @sample,
            %{name: :test, body: body1, return_type: return_type},
            1
          )

        Entity.create(
          db,
          @sample,
          %{name: :test, body: body2, return_type: return_type},
          5
        )

        # return_type never changed, so its changed_at stays at 1.
        assert Entity.field_changed_at(db, @sample, id, :return_type) == 1

        if body1 == body2 do
          assert Entity.field_changed_at(db, @sample, id, :body) == 1
        else
          assert Entity.field_changed_at(db, @sample, id, :body) == 5
        end

        Database.shutdown(db)
      end
    end
  end
end
