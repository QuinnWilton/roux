defmodule Roux.MemoEncodingTest do
  use ExUnit.Case, async: true

  alias Roux.{Blob, Database, Dependencies, Memo}
  alias Roux.Memo.Entry

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    db = Database.new(blob: Blob.open!(Path.join(tmp, "store")))

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    %{db: db}
  end

  test "live checkpoints reuse encodings without replacing decoded values", %{db: db} do
    inline = {:query, :inline}
    blob = {:query, :blob}
    value = List.duplicate(%{text: "same value", number: 1}, 100)
    Memo.put(db, inline, entry(nil))
    Memo.put(db, blob, entry(value, persist: :blob))
    certify(db)

    assert {first, 1} = encodes_during(fn -> persist(db) end)
    assert {second, 0} = encodes_during(fn -> persist(db) end)
    assert first == second
    assert {:ok, nil} = Memo.fetch_value(db, inline)
    assert {:ok, ^value} = Memo.fetch_value(db, blob)
    assert Memo.held_digest(db, blob) == :none
    assert Memo.held_locator(db, blob) == :none

    :ok = Memo.cache_receipts(db, second, db.blob)
    assert {:live, {:term, digest, _bytes}, {:blob, digest}} = encoding(db, blob)
    File.rm!(Blob.path(db.blob, digest))
    assert {:ok, ^value} = Memo.fetch_value(db, blob)
    assert {_repaired, 0} = encodes_during(fn -> persist(db) end)
    assert Blob.member?(db.blob, digest)
  end

  test "equal recomputation keeps cached bytes while replacement clears them", %{db: db} do
    key = {:query, :equal}
    value = %{x: 1, y: List.duplicate(:same, 100)}
    original = entry(value, persist: :blob)
    Memo.put(db, key, original)
    persist(db)
    cached = encoding(db, key)

    Memo.put_unchanged(db, key, %{original | verified_at: 2})
    assert encoding(db, key) == cached
    assert {_result, 0} = encodes_during(fn -> persist(db) end)

    Memo.put(db, key, entry(%{value | x: 1.0}, persist: :blob))
    assert encoding(db, key) == nil
    assert {_result, 1} = encodes_during(fn -> persist(db) end)
    assert {:ok, %{x: x}} = Memo.fetch_value(db, key)
    assert x === 1.0
  end

  test "encoding publication rejects replaced incarnations and exact input changes", %{db: db} do
    for {database, key, put} <- [
          {db, {:query, %{nested: :"$1"}}, &Memo.put/3},
          {db, {:input, :source, :_}, &Memo.put_input/3},
          {%{db | dependencies: nil}, {:query, [:"$14"]}, &Memo.put/3}
        ] do
      put.(database, key, entry(1, persist: :blob))
      generation = Memo.generation(database, key)
      bytes = Blob.encode_term(1)
      put.(database, key, entry(1.0, persist: :blob))
      Memo.remember_encoding(database, key, generation, 1, bytes)
      assert encoding(database, key) == nil

      current = Memo.generation(database, key)
      Memo.remember_encoding(database, key, current, 1.0, Blob.encode_term(1.0))
      assert {:live, {:term, _, _}, nil} = encoding(database, key)
      assert {:ok, value} = Memo.fetch_value(database, key)
      assert value === 1.0
    end
  end

  test "a publisher racing a replacement cannot attach its old receipt", %{db: db} do
    key = {:query, :racing}
    Memo.put(db, key, entry(1, persist: :blob))

    publisher = fn {:term, digest, bytes}, _receipt ->
      Memo.put(db, key, entry(1.0, persist: :blob))
      {:ok, ^digest} = Blob.put_encoded_term(db.blob, digest, bytes)
      {:blob, digest}
    end

    rows = Memo.persisted(db, fn _, _ -> true end, {:encoded, publisher})
    Memo.cache_receipts(db, rows, db.blob)
    assert encoding(db, key) == nil
    assert {:ok, value} = Memo.fetch_value(db, key)
    assert value === 1.0
  end

  test "encoding reuse survives inline write fallback and alternate stores", %{
    db: db,
    tmp_dir: tmp
  } do
    key = {:query, :fallback}
    value = List.duplicate("reusable", 30)
    Memo.put(db, key, entry(value, persist: :blob))
    fallback = fn {:term, _digest, bytes}, _receipt -> bytes end
    [inline] = Memo.persisted(db, fn _, _ -> true end, {:encoded, fallback})
    assert is_binary(elem(inline, 7))
    assert {:ok, ^value} = Memo.fetch_value(db, key)

    other = Blob.open!(Path.join(tmp, "other"))
    assert {rows, 0} = encodes_during(fn -> persist(db, other) end)
    Memo.cache_receipts(db, rows, other)
    assert {:live, {:term, digest, _}, nil} = encoding(db, key)
    assert Blob.get_term(other, digest) == {:ok, value}
    refute Blob.member?(db.blob, digest)
    persist(db)
    assert Blob.get_term(db.blob, digest) == {:ok, value}
  end

  test "restored encodings remain lazy and packed locators expose physical roots", %{db: db} do
    key = {:query, :restored}
    {digest, bytes} = Blob.encode_term(%{value: 1})
    pack = "prefix" <> bytes <> "suffix"
    {:ok, physical} = Blob.put(db.blob, pack)
    handle = {:packed, digest, physical, 6, byte_size(bytes)}
    row = {key, :erlang.phash2(%{value: 1}), 1, 1, [], :medium, [], handle, nil, []}
    Memo.restore_persisted(db, [row])

    assert {:ok, ^handle} = Memo.held_locator(db, key)
    assert Memo.held_digest(db, key) == {:ok, digest}
    assert Roux.Memo.Value.roots(handle) == [physical]
    assert {:ok, %{value: 1}} = Memo.fetch_value(db, key)
    Memo.remember_encoding(db, key, Memo.generation(db, key), %{value: 1}, {digest, bytes})
    assert encoding(db, key) == handle
    File.rm!(Blob.path(db.blob, physical))
    assert Memo.fetch_value(db, key) == :missing
    assert Memo.get(db, key) == :miss
  end

  test "bulk restoration refuses occupied tables and validates before publishing", %{db: db} do
    valid = {{:query, :valid}, 1, 1, 1, [], :medium, [], :erlang.term_to_binary(:valid), nil, []}

    assert_raise ArgumentError, ~r/not a persisted memo entry/, fn ->
      Memo.restore_new(db, [valid, :invalid])
    end

    assert Memo.entries(db) == []

    assert_raise ArgumentError, ~r/duplicate memo key/, fn ->
      Memo.restore_new(db, [valid, valid])
    end

    assert Memo.entries(db) == []
    Memo.put(db, {:query, :existing}, entry(:existing))

    assert_raise ArgumentError, ~r/requires an empty memo table/, fn ->
      Memo.restore_new(db, [valid])
    end

    assert {:ok, :existing} = Memo.fetch_value(db, {:query, :existing})
    assert :miss = Memo.fetch_value(db, {:query, :valid})
  end

  test "persistence equality observes every stored dependency field", %{db: db} do
    key = {:query, %{literal: :_}}
    original = entry(nil)
    Memo.put(db, key, original)
    generation = Memo.generation(db, key)
    assert Memo.same_persistence?(db, key, generation, original)
    refute Memo.same_persistence?(db, {:query, :missing}, generation, original)
    persist(db)
    assert Memo.same_persistence?(db, key, generation, original)

    for {field, changed} <- [
          hash: 0,
          changed_at: 2,
          verified_at: 2,
          dependencies: [{:query, :other}],
          durability: :high,
          output_entities: [{SomeEntity, 1}],
          code_version: "other",
          persist: :blob,
          blobs: [String.duplicate("a", 64)]
        ] do
      refute Memo.same_persistence?(db, key, generation, Map.put(original, field, changed)),
             inspect(field)
    end

    Memo.put(db, key, original)
    refute Memo.same_persistence?(db, key, generation, original)

    input = {:input, :source, :key}
    integer = entry(1, hash: 0)
    Memo.put_input(db, input, integer)
    assert Memo.same_persistence?(db, input, nil, integer)
    persist(db)
    assert Memo.same_persistence?(db, input, nil, integer)
    Memo.put_input(db, input, %{integer | value: 1.0})
    refute Memo.same_persistence?(db, input, nil, integer)
  end

  defp encoding(db, key), do: :ets.lookup_element(db.memo_table, key, 9)

  defp certify(db) do
    token = Dependencies.snapshot(db)

    Memo.reduce_dependencies(db, :ok, fn key, _deps, :ok ->
      Dependencies.certify(db, key, Memo.generation(db, key), token)
    end)
  end

  defp persist(db, store \\ nil) do
    store = store || db.blob

    publisher = fn
      {:inline, bytes}, _receipt ->
        bytes

      {:term, digest, bytes}, _receipt ->
        {:ok, ^digest} = Blob.put_encoded_term(store, digest, bytes)
        {:blob, digest}

      nil, handle ->
        handle
    end

    Memo.persisted(db, fn _, _ -> true end, {:encoded, publisher})
  end

  # Trace only this test process; concurrent tests' encodes do not count.
  defp encodes_during(fun) do
    collector = spawn_link(fn -> collect_encodes(0) end)
    :erlang.trace_pattern({Blob, :encode_term, 1}, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, collector}])

    result =
      try do
        fun.()
      after
        :erlang.trace(self(), false, [:call])
      end

    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^ref}
    send(collector, {:count, self()})
    assert_receive {:encodes, count}
    {result, count}
  end

  defp collect_encodes(count) do
    receive do
      {:trace, _pid, :call, {Blob, :encode_term, _args}} -> collect_encodes(count + 1)
      {:count, pid} -> send(pid, {:encodes, count})
    end
  end

  test "generation checks preserve arbitrary keys and ignore stale generations", %{db: db} do
    keys = [
      {:ordinary, "source.ex"},
      {:query, %{nested: :"$1"}},
      {:query, :_},
      {:query, :"$1"},
      {:query, [:_, {:nested, :"$14"} | :tail]}
    ]

    for key <- keys do
      Memo.put(db, key, entry(:original))
      original = Memo.generation(db, key)
      assert :ok = Memo.verify_generation(db, key, original, 2, :high)
      assert {:ok, 2, :high} = Memo.verification_state(db, key)

      Memo.put(db, key, entry(:replacement))
      current = Memo.generation(db, key)
      assert current != original
      assert :ok = Memo.verify_generation(db, key, original, 9, :low)
      assert {:ok, 1, :medium} = Memo.verification_state(db, key)
      assert :ok = Memo.verify_generation(db, key, current, 3, nil)
      assert {:ok, 3, :medium} = Memo.verification_state(db, key)
    end

    for key <- keys do
      assert {:ok, %Entry{value: :replacement, verified_at: 3, durability: :medium}} =
               Memo.get(db, key)
    end
  end

  defp entry(value, attrs \\ []) do
    struct!(
      Entry,
      Keyword.merge(
        [
          value: value,
          hash: :erlang.phash2(value),
          changed_at: 1,
          verified_at: 1,
          dependencies: [],
          durability: :medium,
          output_entities: []
        ],
        attrs
      )
    )
  end
end
