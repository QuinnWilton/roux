defmodule Roux.MemoTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.Database
  alias Roux.Memo
  alias Roux.Memo.Entry

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

  defp make_entry(attrs \\ %{}) do
    defaults = %{
      value: :default_value,
      hash: :erlang.phash2(:default_value),
      changed_at: 1,
      verified_at: 1,
      dependencies: [],
      durability: :low,
      output_entities: []
    }

    Map.merge(defaults, attrs) |> then(&struct!(Entry, Map.to_list(&1)))
  end

  # -- Unit tests --

  describe "get/2" do
    test "returns :miss for a key that was never stored", %{db: db} do
      assert Memo.get(db, {:parse, "file.ex"}) == :miss
    end
  end

  describe "put/3 + get/2" do
    test "round-trips an entry", %{db: db} do
      key = {:parse, "file.ex"}
      entry = make_entry(%{value: [1, 2, 3], hash: :erlang.phash2([1, 2, 3])})

      assert :ok = Memo.put(db, key, entry)
      assert {:ok, ^entry} = Memo.get(db, key)
    end

    test "overwrites an existing entry", %{db: db} do
      key = {:tokenize, "main.ex"}
      entry1 = make_entry(%{value: :old, hash: :erlang.phash2(:old)})

      entry2 =
        make_entry(%{value: :new, hash: :erlang.phash2(:new), changed_at: 2, verified_at: 2})

      Memo.put(db, key, entry1)
      Memo.put(db, key, entry2)

      assert {:ok, ^entry2} = Memo.get(db, key)
    end

    test "stores complex values and dependencies", %{db: db} do
      key = {:resolve, {:module, MyApp}}

      entry =
        make_entry(%{
          value: %{functions: [:foo, :bar], arity: 2},
          hash: :erlang.phash2(%{functions: [:foo, :bar], arity: 2}),
          changed_at: 5,
          verified_at: 7,
          dependencies: [{:parse, "file.ex"}, {:tokenize, "file.ex"}],
          durability: :high,
          output_entities: [{MyEntity, :entity_1}]
        })

      Memo.put(db, key, entry)
      assert {:ok, ^entry} = Memo.get(db, key)
    end
  end

  describe "update_verified/3" do
    test "changes only verified_at, all other fields preserved", %{db: db} do
      key = {:parse, "file.ex"}

      entry =
        make_entry(%{
          value: {:ast, :node},
          hash: :erlang.phash2({:ast, :node}),
          changed_at: 3,
          verified_at: 3,
          dependencies: [{:tokenize, "file.ex"}],
          durability: :medium,
          output_entities: [{SomeEntity, :id}]
        })

      Memo.put(db, key, entry)
      Memo.update_verified(db, key, 10)

      assert {:ok, updated} = Memo.get(db, key)
      assert updated.verified_at == 10
      assert updated.value == entry.value
      assert updated.hash == entry.hash
      assert updated.changed_at == entry.changed_at
      assert updated.dependencies == entry.dependencies
      assert updated.durability == entry.durability
      assert updated.output_entities == entry.output_entities
    end

    test "is a no-op when key doesn't exist", %{db: db} do
      assert :ok = Memo.update_verified(db, {:missing, :key}, 5)
      assert Memo.get(db, {:missing, :key}) == :miss
    end
  end

  describe "delete/2" do
    test "removes an existing entry", %{db: db} do
      key = {:parse, "file.ex"}
      Memo.put(db, key, make_entry())
      assert {:ok, _} = Memo.get(db, key)

      assert :ok = Memo.delete(db, key)
      assert Memo.get(db, key) == :miss
    end

    test "is a no-op when key doesn't exist", %{db: db} do
      assert :ok = Memo.delete(db, {:nonexistent, :key})
    end
  end

  describe "delete_all/1" do
    test "clears all entries", %{db: db} do
      Memo.put(db, {:a, 1}, make_entry())
      Memo.put(db, {:b, 2}, make_entry())
      Memo.put(db, {:c, 3}, make_entry())

      assert :ok = Memo.delete_all(db)

      assert Memo.get(db, {:a, 1}) == :miss
      assert Memo.get(db, {:b, 2}) == :miss
      assert Memo.get(db, {:c, 3}) == :miss
    end

    test "is a no-op on an empty table", %{db: db} do
      assert :ok = Memo.delete_all(db)
    end
  end

  describe "entries/1" do
    test "returns all entries with their keys", %{db: db} do
      entry_a = make_entry(%{value: :a, hash: :erlang.phash2(:a)})
      entry_b = make_entry(%{value: :b, hash: :erlang.phash2(:b)})

      Memo.put(db, {:q, 1}, entry_a)
      Memo.put(db, {:q, 2}, entry_b)

      result = Memo.entries(db)
      assert length(result) == 2

      result_map = Map.new(result)
      assert result_map[{:q, 1}] == entry_a
      assert result_map[{:q, 2}] == entry_b
    end

    test "returns [] on empty table", %{db: db} do
      assert Memo.entries(db) == []
    end
  end

  # -- Property tests --

  describe "properties" do
    property "put then get always round-trips" do
      check all(
              query_name <- atom(:alphanumeric),
              key <- term(),
              value <- term(),
              changed_at <- positive_integer(),
              verified_at <- positive_integer(),
              durability <- member_of([:high, :medium, :low])
            ) do
        db = Database.new()

        entry = %Entry{
          value: value,
          hash: :erlang.phash2(value),
          changed_at: changed_at,
          verified_at: verified_at,
          dependencies: [],
          durability: durability,
          output_entities: []
        }

        Memo.put(db, {query_name, key}, entry)
        assert {:ok, ^entry} = Memo.get(db, {query_name, key})

        Database.shutdown(db)
      end
    end

    property "entries count equals number of distinct keys inserted" do
      check all(
              keys <-
                list_of(
                  {atom(:alphanumeric), integer()},
                  min_length: 0,
                  max_length: 20
                )
            ) do
        db = Database.new()

        for key <- keys do
          Memo.put(db, key, make_entry())
        end

        distinct = keys |> Enum.uniq() |> length()
        assert length(Memo.entries(db)) == distinct

        Database.shutdown(db)
      end
    end

    property "delete then get always returns :miss" do
      check all(
              query_name <- atom(:alphanumeric),
              key <- term()
            ) do
        db = Database.new()
        qk = {query_name, key}

        Memo.put(db, qk, make_entry())
        Memo.delete(db, qk)
        assert Memo.get(db, qk) == :miss

        Database.shutdown(db)
      end
    end

    property "arbitrary operation sequences are consistent with a map model" do
      check all(ops <- list_of(operation_gen(), min_length: 1, max_length: 30)) do
        db = Database.new()

        model =
          Enum.reduce(ops, %{}, fn op, model ->
            case op do
              {:put, key, entry} ->
                Memo.put(db, key, entry)
                Map.put(model, key, entry)

              {:get, key} ->
                result = Memo.get(db, key)

                expected =
                  case Map.fetch(model, key) do
                    {:ok, entry} -> {:ok, entry}
                    :error -> :miss
                  end

                assert result == expected
                model

              {:delete, key} ->
                Memo.delete(db, key)
                Map.delete(model, key)

              {:update_verified, key, rev} ->
                Memo.update_verified(db, key, rev)

                case Map.fetch(model, key) do
                  {:ok, %Entry{} = entry} ->
                    Map.put(model, key, %Entry{entry | verified_at: rev})

                  :error ->
                    model
                end
            end
          end)

        # Final snapshot must match the model.
        entries = Memo.entries(db) |> Map.new()
        assert entries == model

        Database.shutdown(db)
      end
    end
  end

  # -- Generators --

  defp operation_gen do
    one_of([
      gen all(key <- key_gen(), entry <- entry_gen()) do
        {:put, key, entry}
      end,
      gen all(key <- key_gen()) do
        {:get, key}
      end,
      gen all(key <- key_gen()) do
        {:delete, key}
      end,
      gen all(key <- key_gen(), rev <- positive_integer()) do
        {:update_verified, key, rev}
      end
    ])
  end

  # Small key space so operations frequently collide on the same keys.
  defp key_gen do
    tuple({member_of([:parse, :tokenize, :resolve]), integer(0..3)})
  end

  defp entry_gen do
    gen all(
          value <- one_of([integer(), atom(:alphanumeric), binary()]),
          changed_at <- positive_integer(),
          verified_at <- positive_integer(),
          durability <- member_of([:high, :medium, :low])
        ) do
      %Entry{
        value: value,
        hash: :erlang.phash2(value),
        changed_at: changed_at,
        verified_at: verified_at,
        dependencies: [],
        durability: durability,
        output_entities: []
      }
    end
  end
end
