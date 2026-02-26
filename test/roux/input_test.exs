defmodule Roux.InputTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.Database
  alias Roux.Input
  alias Roux.Input.{Definition, NotSetError}
  alias Roux.Revision

  setup do
    db = Database.new()

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    %{db: db}
  end

  # -- Helpers --

  defp register_input!(db, name, opts \\ []) do
    definition = Input.define(name, opts)
    Input.register(db, definition)
    definition
  end

  # -- define/2 --

  describe "define/2" do
    test "creates a definition with default durability :medium" do
      assert %Definition{name: :source, durability: :medium} = Input.define(:source)
    end

    test "creates a definition with explicit durability" do
      assert %Definition{name: :config, durability: :high} =
               Input.define(:config, durability: :high)

      assert %Definition{name: :active, durability: :low} =
               Input.define(:active, durability: :low)
    end
  end

  # -- register/2 --

  describe "register/2" do
    test "stores definition (verified via set/get round-trip)", %{db: db} do
      register_input!(db, :source)

      Input.set(db, :source, "file.ex", "contents")
      assert Input.get(db, :source, "file.ex") == "contents"
    end
  end

  # -- set/4 + get/3 --

  describe "set/4 + get/3" do
    test "round-trips a value", %{db: db} do
      register_input!(db, :source)

      Input.set(db, :source, "file.ex", "defmodule Foo do\nend")
      assert Input.get(db, :source, "file.ex") == "defmodule Foo do\nend"
    end

    test "same value twice does not advance revision", %{db: db} do
      register_input!(db, :source)

      Input.set(db, :source, "file.ex", "contents")
      rev_after_first = Revision.current(db.revision)

      Input.set(db, :source, "file.ex", "contents")
      rev_after_second = Revision.current(db.revision)

      assert rev_after_first == rev_after_second
    end

    test "different value advances revision", %{db: db} do
      register_input!(db, :source)

      Input.set(db, :source, "file.ex", "v1")
      rev_after_first = Revision.current(db.revision)

      Input.set(db, :source, "file.ex", "v2")
      rev_after_second = Revision.current(db.revision)

      assert rev_after_second > rev_after_first
    end

    test "stores complex values", %{db: db} do
      register_input!(db, :config, durability: :high)

      value = %{target: :elixir_ast, features: [:debug, :trace]}
      Input.set(db, :config, :project, value)
      assert Input.get(db, :config, :project) == value
    end

    test "on unregistered input raises ArgumentError", %{db: db} do
      assert_raise ArgumentError, ~r/not registered/, fn ->
        Input.set(db, :nonexistent, "key", "value")
      end
    end
  end

  # -- get/3 --

  describe "get/3" do
    test "on unset key raises NotSetError", %{db: db} do
      register_input!(db, :source)

      error =
        assert_raise NotSetError, fn ->
          Input.get(db, :source, "missing.ex")
        end

      assert error.input_name == :source
      assert error.key == "missing.ex"
      assert Exception.message(error) =~ "input :source has not been set for key"
    end
  end

  # -- get_with_revision/3 --

  describe "get_with_revision/3" do
    test "returns {value, revision}", %{db: db} do
      register_input!(db, :source)

      Input.set(db, :source, "file.ex", "contents")
      {value, changed_at} = Input.get_with_revision(db, :source, "file.ex")

      assert value == "contents"
      assert is_integer(changed_at)
      assert changed_at > 0
    end

    test "revision tracks actual changes, not redundant sets", %{db: db} do
      register_input!(db, :source)

      Input.set(db, :source, "file.ex", "v1")
      {_, rev1} = Input.get_with_revision(db, :source, "file.ex")

      # Same value — no change.
      Input.set(db, :source, "file.ex", "v1")
      {_, rev1_again} = Input.get_with_revision(db, :source, "file.ex")
      assert rev1 == rev1_again

      # Different value — changed_at advances.
      Input.set(db, :source, "file.ex", "v2")
      {_, rev2} = Input.get_with_revision(db, :source, "file.ex")
      assert rev2 > rev1
    end

    test "on unset key raises NotSetError", %{db: db} do
      register_input!(db, :source)

      assert_raise NotSetError, fn ->
        Input.get_with_revision(db, :source, "missing.ex")
      end
    end
  end

  # -- delete/3 --

  describe "delete/3" do
    test "removes value (subsequent get raises)", %{db: db} do
      register_input!(db, :source)

      Input.set(db, :source, "file.ex", "contents")
      assert Input.get(db, :source, "file.ex") == "contents"

      Input.delete(db, :source, "file.ex")

      assert_raise NotSetError, fn ->
        Input.get(db, :source, "file.ex")
      end
    end

    test "advances revision", %{db: db} do
      register_input!(db, :source)

      Input.set(db, :source, "file.ex", "contents")
      rev_before = Revision.current(db.revision)

      Input.delete(db, :source, "file.ex")
      rev_after = Revision.current(db.revision)

      assert rev_after > rev_before
    end

    test "does not advance revision when key does not exist", %{db: db} do
      register_input!(db, :source)

      rev_before = Revision.current(db.revision)
      Input.delete(db, :source, "nonexistent.ex")
      rev_after = Revision.current(db.revision)

      assert rev_after == rev_before
    end
  end

  # -- keys/2 --

  describe "keys/2" do
    test "returns all set keys", %{db: db} do
      register_input!(db, :source)

      Input.set(db, :source, "a.ex", "a")
      Input.set(db, :source, "b.ex", "b")
      Input.set(db, :source, "c.ex", "c")

      keys = Input.keys(db, :source) |> Enum.sort()
      assert keys == ["a.ex", "b.ex", "c.ex"]
    end

    test "on empty input returns []", %{db: db} do
      register_input!(db, :source)
      assert Input.keys(db, :source) == []
    end

    test "does not return keys from other inputs", %{db: db} do
      register_input!(db, :source)
      register_input!(db, :config, durability: :high)

      Input.set(db, :source, "file.ex", "contents")
      Input.set(db, :config, :target, :elixir_ast)

      assert Input.keys(db, :source) == ["file.ex"]
      assert Input.keys(db, :config) == [:target]
    end

    test "reflects deletions", %{db: db} do
      register_input!(db, :source)

      Input.set(db, :source, "a.ex", "a")
      Input.set(db, :source, "b.ex", "b")
      Input.delete(db, :source, "a.ex")

      assert Input.keys(db, :source) == ["b.ex"]
    end
  end

  # -- Property tests --

  describe "properties" do
    property "round-trip: set then get returns the value" do
      check all(
              input_name <- atom(:alphanumeric),
              key <- term(),
              value <- term()
            ) do
        db = Database.new()
        register_input!(db, input_name)

        Input.set(db, input_name, key, value)
        assert Input.get(db, input_name, key) == value

        Database.shutdown(db)
      end
    end

    property "early cutoff: setting same value never changes revision" do
      check all(
              input_name <- atom(:alphanumeric),
              key <- one_of([integer(), binary(), atom(:alphanumeric)]),
              value <- one_of([integer(), binary(), atom(:alphanumeric)])
            ) do
        db = Database.new()
        register_input!(db, input_name)

        Input.set(db, input_name, key, value)
        rev_after_first = Revision.current(db.revision)

        Input.set(db, input_name, key, value)
        rev_after_second = Revision.current(db.revision)

        assert rev_after_first == rev_after_second

        Database.shutdown(db)
      end
    end

    property "keys consistency: set N distinct keys, keys/2 returns exactly those" do
      check all(
              input_name <- atom(:alphanumeric),
              keys <-
                list_of(one_of([integer(0..20), binary(min_length: 1, max_length: 5)]),
                  min_length: 0,
                  max_length: 15
                )
            ) do
        db = Database.new()
        register_input!(db, input_name)

        for key <- keys do
          Input.set(db, input_name, key, :some_value)
        end

        expected = keys |> Enum.uniq() |> Enum.sort()
        actual = Input.keys(db, input_name) |> Enum.sort()
        assert actual == expected

        Database.shutdown(db)
      end
    end
  end
end
