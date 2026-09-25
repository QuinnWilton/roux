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

  describe "value-free accessors" do
    # Validation asks only ever three things of an entry: has it been
    # verified this revision, how durable is it, and what does it depend
    # on. Reading any of those through get/2 deep-copies the entry's value
    # out of ETS — measured at 747x the cost on realistic fact rows, and
    # validation touches every dependency of every node, so it dominated
    # the per-edit budget. These accessors read the fields directly.
    #
    # The value is never involved, so these must agree with get/2 exactly
    # while never depending on what the value is.

    test "dep_state/2 agrees with get/2", %{db: db} do
      entry = make_entry(%{changed_at: 7, durability: :medium})
      Memo.put(db, {:q, :k}, entry)

      assert {:ok, 7, :medium} = Memo.dep_state(db, {:q, :k})
      assert {:ok, %Entry{changed_at: 7, durability: :medium}} = Memo.get(db, {:q, :k})
    end

    test "verification_state/2 agrees with get/2", %{db: db} do
      Memo.put(db, {:q, :k}, make_entry(%{verified_at: 9, durability: :low}))

      assert {:ok, 9, :low} = Memo.verification_state(db, {:q, :k})
    end

    test "dependencies/2 agrees with get/2", %{db: db} do
      deps = [{:other, :k}, {:input, :src, "a"}, {:entity_field, Some.Entity, 1, :body}]
      Memo.put(db, {:q, :k}, make_entry(%{dependencies: deps}))

      assert {:ok, ^deps} = Memo.dependencies(db, {:q, :k})
    end

    test "all three miss on an absent key", %{db: db} do
      assert Memo.dep_state(db, {:nope, :k}) == :miss
      assert Memo.verification_state(db, {:nope, :k}) == :miss
      assert Memo.dependencies(db, {:nope, :k}) == :miss
    end

    test "they read the entry, not a value-shaped guess", %{db: db} do
      # A value that would break any accessor secretly reconstructing the
      # entry from position 2, and one whose shape resembles the fields
      # being read.
      Memo.put(db, {:q, :k}, make_entry(%{value: {1, 2, 3, 4, 5, 6, 7, 8}, changed_at: 3}))
      assert {:ok, 3, _} = Memo.dep_state(db, {:q, :k})

      Memo.put(
        db,
        {:q, :big},
        make_entry(%{value: List.duplicate(["a", "b"], 1000), changed_at: 4})
      )

      assert {:ok, 4, _} = Memo.dep_state(db, {:q, :big})
    end

    test "they track update_verified/4", %{db: db} do
      Memo.put(db, {:q, :k}, make_entry(%{verified_at: 1, durability: :high}))
      Memo.update_verified(db, {:q, :k}, 5, :low)

      assert {:ok, 5, :low} = Memo.verification_state(db, {:q, :k})
      assert {:ok, _changed_at, :low} = Memo.dep_state(db, {:q, :k})
    end
  end

  describe "persistence" do
    # A manifest carries each entry with its value in the external term
    # format, and restore puts it back that way: the value is decoded by
    # the first read that needs it, and goes out to the next manifest in
    # the encoding it came in with.

    defp persisted_row(key, encoded, attrs \\ %{}) do
      entry = make_entry(attrs)

      {key, entry.hash, entry.changed_at, entry.verified_at, entry.dependencies, entry.durability,
       entry.output_entities, encoded}
    end

    defp keep_all(_key, _durability), do: true

    test "restored entries read back as they were written", %{db: db} do
      Memo.put(db, {:q, :a}, make_entry(%{value: %{rows: [["a", 1]]}, changed_at: 3}))
      Memo.put(db, {:input, :src, "b"}, make_entry(%{value: "text", durability: :medium}))

      restored = Database.new()

      try do
        :ok = Memo.restore_persisted(restored, Memo.persisted(db, &keep_all/2))

        assert Enum.sort(Memo.entries(restored)) == Enum.sort(Memo.entries(db))
        assert Memo.get(restored, {:q, :a}) == Memo.get(db, {:q, :a})
        assert Memo.get(restored, {:input, :src, "b"}) == Memo.get(db, {:input, :src, "b"})
      after
        Database.shutdown(restored)
      end
    end

    test "the value-free accessors never decode a restored value", %{db: db} do
      # Not the external term format: any accessor that decoded it would
      # raise.
      row =
        persisted_row({:q, :k}, "not a term", %{
          changed_at: 4,
          verified_at: 6,
          durability: :medium,
          dependencies: [{:dep, 1}]
        })

      :ok = Memo.restore_persisted(db, [row])

      assert Memo.dep_state(db, {:q, :k}) == {:ok, 4, :medium}
      assert Memo.verification_state(db, {:q, :k}) == {:ok, 6, :medium}
      assert Memo.dependencies(db, {:q, :k}) == {:ok, [{:dep, 1}]}
      assert Memo.changed_at(db, {:q, :k}) == {:ok, 4}
      assert Memo.durability(db, {:q, :k}) == {:ok, :medium}
      assert :ok = Memo.update_verified(db, {:q, :k}, 7, :high)
      assert Memo.verification_state(db, {:q, :k}) == {:ok, 7, :high}

      assert_raise ArgumentError, fn -> Memo.get(db, {:q, :k}) end
    end

    test "a restored value goes back out in the encoding it came in with", %{db: db} do
      # Uncompressed, which `persisted/2` would never produce itself: an
      # entry that was re-encoded would come out compressed.
      encoded = :erlang.term_to_binary(List.duplicate("row", 100))
      :ok = Memo.restore_persisted(db, [persisted_row({:q, :k}, encoded)])

      assert [{{:q, :k}, _, _, _, _, _, _, ^encoded}] = Memo.persisted(db, &keep_all/2)
      assert {:ok, %Entry{value: value}} = Memo.get(db, {:q, :k})
      assert value == List.duplicate("row", 100)

      # Reading it does not replace the encoding, and neither does
      # verifying it again.
      Memo.update_verified(db, {:q, :k}, 9)
      assert [{{:q, :k}, _, _, 9, _, _, _, ^encoded}] = Memo.persisted(db, &keep_all/2)
    end

    test "put/3 over a restored entry replaces its encoding", %{db: db} do
      :ok = Memo.restore_persisted(db, [persisted_row({:q, :k}, "not a term")])
      Memo.put(db, {:q, :k}, make_entry(%{value: :new, hash: :erlang.phash2(:new)}))

      assert {:ok, %Entry{value: :new}} = Memo.get(db, {:q, :k})
      assert [{{:q, :k}, _, _, _, _, _, _, encoded}] = Memo.persisted(db, &keep_all/2)
      assert :erlang.binary_to_term(encoded) == :new
    end

    test "persisted/2 offers each entry's key and durability to keep?", %{db: db} do
      Memo.put(db, {:q, :low}, make_entry(%{durability: :low}))
      Memo.put(db, {:q, :high}, make_entry(%{durability: :high}))
      :ok = Memo.restore_persisted(db, [persisted_row({:q, :restored}, "not a term")])

      kept = Memo.persisted(db, fn _key, durability -> durability != :low end)

      assert Enum.sort(Enum.map(kept, &elem(&1, 0))) == [{:q, :high}]
    end

    test "restore_persisted/2 refuses anything but persisted entries", %{db: db} do
      assert_raise ArgumentError, ~r/not a persisted memo entry/, fn ->
        Memo.restore_persisted(db, [{{:q, :k}, make_entry()}])
      end

      assert_raise ArgumentError, ~r/not a persisted memo entry/, fn ->
        Memo.restore_persisted(db, [put_elem(persisted_row({:q, :k}, "x"), 7, :not_binary)])
      end

      assert Memo.get(db, {:q, :k}) == :miss
    end

    test "decode_persisted/1 is what a restore would read", %{db: db} do
      Memo.put(db, {:q, :k}, make_entry(%{value: {:a, "b"}, changed_at: 2}))
      [row] = Memo.persisted(db, &keep_all/2)

      assert Memo.decode_persisted(row) == {{:q, :k}, elem(Memo.get(db, {:q, :k}), 1)}
    end

    test "Roux.Input.keys/2 lists restored inputs", %{db: db} do
      :ok =
        Memo.restore_persisted(db, [
          persisted_row({:input, :src, "a"}, :erlang.term_to_binary("x")),
          persisted_row({:q, :k}, :erlang.term_to_binary("y"))
        ])

      assert Roux.Input.keys(db, :src) == ["a"]
    end

    property "restore_persisted(persisted(db)) reproduces every entry" do
      check all(
              entries <-
                uniq_list_of(
                  tuple(
                    {tuple({atom(:alphanumeric), term()}), term(), positive_integer(),
                     member_of([:high, :medium, :low])}
                  ),
                  uniq_fun: &elem(&1, 0),
                  max_length: 20
                )
            ) do
        db = Database.new()
        restored = Database.new()

        try do
          for {key, value, changed_at, durability} <- entries do
            Memo.put(
              db,
              key,
              make_entry(%{
                value: value,
                hash: :erlang.phash2(value),
                changed_at: changed_at,
                verified_at: changed_at,
                durability: durability,
                dependencies: [key]
              })
            )
          end

          persisted = Memo.persisted(db, &keep_all/2)
          :ok = Memo.restore_persisted(restored, persisted)

          assert Enum.sort(Memo.entries(restored)) == Enum.sort(Memo.entries(db))

          for {key, _, _, _} <- entries do
            assert Memo.dep_state(restored, key) == Memo.dep_state(db, key)
            assert Memo.get(restored, key) == Memo.get(db, key)
          end

          # A second round trip carries the same bytes: nothing was
          # encoded again.
          assert Enum.sort(Memo.persisted(restored, &keep_all/2)) == Enum.sort(persisted)
        after
          Database.shutdown(db)
          Database.shutdown(restored)
        end
      end
    end
  end
end
