defmodule Roux.Lang.ManifestTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  alias Roux.{Blob, Database, Input, Intern, Memo, Revision, Runtime}
  alias Roux.Lang.Manifest
  alias Roux.Memo.Entry
  alias Roux.Test.PersistQueries

  @moduletag :tmp_dir

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

  # -- write/3 and load/1 --

  describe "write and load round-trip" do
    test "round-trips manifest data", %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")

      # Set up some state in the database.
      Database.register_input(db, :source_text, durability: :low)
      Input.set(db, :source_text, "a.mini", "hello")

      source_meta = %{"a.mini" => %{mtime: {{2024, 1, 1}, {0, 0, 0}}, hash: 12_345}}
      Manifest.write(db, source_meta, path)

      assert {:ok, data} = Manifest.load(path)
      assert data.sources == source_meta
      assert is_map(data.revision)
      assert is_list(data.memo_entries)
    end
  end

  # -- load/1 error cases --

  describe "load/1" do
    test "returns :error for missing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nonexistent.roux")
      assert :error = Manifest.load(path)
    end

    test "returns :error for corrupt data", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "corrupt.roux")
      File.write!(path, :crypto.strong_rand_bytes(64))
      assert :error = Manifest.load(path)
    end

    test "returns :error for a bare term, as formats 1 to 3 were", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "wrong_vsn.roux")

      data = %{
        vsn: 9999,
        sources: %{},
        memo_entries: [],
        entity_data: [],
        intern_data: [],
        revision: %{}
      }

      File.write!(path, :erlang.term_to_binary(data))
      assert :error = Manifest.load(path)
    end

    test "returns :error for a format-3 manifest (entries compressed one by one)", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "format3.roux")

      entry = %Entry{
        value: "hello",
        hash: :erlang.phash2("hello"),
        changed_at: 1,
        verified_at: 1,
        dependencies: [],
        durability: :medium,
        output_entities: []
      }

      data = %{
        vsn: 3,
        sources: %{},
        memo_entries: [:erlang.term_to_binary({{:input, :src, "a"}, entry}, compressed: 1)],
        entity_data: [],
        intern_data: [{:names, %{version: 2, forward: [{"a", 1}], counter: 1}}],
        revision: %{counter: 1, high: 0, medium: 1, low: 0}
      }

      File.write!(path, :erlang.term_to_binary(data, compressed: 1))
      assert :error = Manifest.load(path)
    end

    test "returns :error for a format-2 manifest (intern tables stored twice)", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "format2.roux")

      data = %{
        vsn: 2,
        sources: %{},
        memo_entries: [],
        entity_data: [],
        intern_data: [{:names, %{forward: [{"a", 1}], reverse: [{1, "a"}], counter: 1}}],
        revision: %{}
      }

      File.write!(path, :erlang.term_to_binary(data))
      assert :error = Manifest.load(path)
    end
  end

  # -- restore/2 --

  describe "restore/2" do
    test "restores revision state", %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")

      # Advance the revision a few times before writing.
      Database.register_input(db, :source_text, durability: :medium)
      Input.set(db, :source_text, "a.mini", "v1")
      Input.set(db, :source_text, "b.mini", "v2")

      saved_rev = Revision.current(db.revision)
      assert saved_rev > 0

      Manifest.write(db, %{}, path)
      Database.shutdown(db)

      # Restore into a fresh database.
      db2 = Database.new()

      try do
        {:ok, data} = Manifest.load(path)
        Manifest.restore(db2, data)

        assert Revision.current(db2.revision) == saved_rev
      after
        Database.shutdown(db2)
      end
    end

    test "restores memo entries", %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")

      # Register input and set a value (creates a memo entry).
      Database.register_input(db, :source_text, durability: :medium)
      Input.set(db, :source_text, "a.mini", "hello")

      Manifest.write(db, %{}, path)
      Database.shutdown(db)

      # Restore into a fresh database.
      db2 = Database.new()

      try do
        {:ok, data} = Manifest.load(path)
        Manifest.restore(db2, data)

        # The memo entry should be accessible.
        assert {:ok, %Entry{value: "hello"}} = Memo.get(db2, {:input, :source_text, "a.mini"})
      after
        Database.shutdown(db2)
      end
    end

    test "restores entity data", %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")

      # Register an entity type and create an entity.
      Database.register_entity(db, Roux.Test.ManifestEntity)

      [{Roux.Test.ManifestEntity, tid}] =
        :ets.lookup(db.entity_registry, Roux.Test.ManifestEntity)

      :ets.insert(tid, {1, %{name: %{value: "foo", hash: 123, changed_at: 1}}, 0})

      Manifest.write(db, %{}, path)
      Database.shutdown(db)

      db2 = Database.new()

      try do
        {:ok, data} = Manifest.load(path)
        Manifest.restore(db2, data)

        [{Roux.Test.ManifestEntity, tid2}] =
          :ets.lookup(db2.entity_registry, Roux.Test.ManifestEntity)

        assert [{1, %{name: %{value: "foo"}}, 0}] = :ets.lookup(tid2, 1)
      after
        Database.shutdown(db2)
      end
    end

    test "restores intern data", %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")

      # Create an intern table and intern some values.
      intern = Database.intern_table(db, :test_intern)
      id1 = Intern.intern(intern, "hello")
      id2 = Intern.intern(intern, "world")

      Manifest.write(db, %{}, path)
      Database.shutdown(db)

      db2 = Database.new()

      try do
        {:ok, data} = Manifest.load(path)
        Manifest.restore(db2, data)

        intern2 = Database.intern_table(db2, :test_intern)
        assert {:ok, ^id1} = Intern.lookup(intern2, "hello")
        assert {:ok, ^id2} = Intern.lookup(intern2, "world")
        assert {:ok, "hello"} = Intern.resolve(intern2, id1)
      after
        Database.shutdown(db2)
      end
    end
  end

  # -- durability filtering --

  describe "durability filtering" do
    test "low-durability input entries are persisted in manifest", %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")

      # Create a :low durability input — should be persisted (inputs always are).
      Database.register_input(db, :source_text, durability: :low)
      Input.set(db, :source_text, "a.mini", "low content")

      # Create a :medium durability input — should also be persisted.
      Database.register_input(db, :persistent_data, durability: :medium)
      Input.set(db, :persistent_data, "b.dat", "medium content")

      Manifest.write(db, %{}, path)

      {:ok, data} = Manifest.load(path)

      # Both entries should be present — input entries are always kept.
      input_entries =
        Enum.filter(Manifest.memo_entries(data), fn
          {{:input, _, _}, _entry} -> true
          _ -> false
        end)

      assert length(input_entries) == 2
    end

    test "low-durability derived entries are excluded from manifest", %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")

      # Manually insert a :low durability derived memo entry.
      Memo.put(db, {:query, :hover_info, "a.mini"}, %Entry{
        value: "hover data",
        hash: :erlang.phash2("hover data"),
        changed_at: 1,
        verified_at: 1,
        durability: :low,
        dependencies: [],
        output_entities: []
      })

      # And a :medium durability derived memo entry.
      Memo.put(db, {:query, :diagnostics, "a.mini"}, %Entry{
        value: "diag data",
        hash: :erlang.phash2("diag data"),
        changed_at: 1,
        verified_at: 1,
        durability: :medium,
        dependencies: [],
        output_entities: []
      })

      Manifest.write(db, %{}, path)

      {:ok, data} = Manifest.load(path)

      keys = Enum.map(Manifest.memo_entries(data), fn {key, _} -> key end)
      refute {:query, :hover_info, "a.mini"} in keys
      assert {:query, :diagnostics, "a.mini"} in keys
    end
  end

  # -- source_metadata/1 --

  describe "source_metadata/1" do
    test "collects mtime and hash for files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.mini")
      File.write!(path, "hello world")

      meta = Manifest.source_metadata([path])
      assert map_size(meta) == 1
      assert %{mtime: mtime, hash: hash} = meta[path]
      assert is_tuple(mtime)
      assert hash == :erlang.phash2("hello world")
    end
  end

  # -- persisted metadata --

  # A database with every kind of state a manifest carries: inputs,
  # derived entries with structured values, an intern table, entity rows
  # and a revision past zero.
  defp populate(db) do
    Database.register_input(db, :source_text, durability: :medium)
    Input.set(db, :source_text, "a.mini", "alpha")
    Input.set(db, :source_text, "b.mini", "beta")

    for file <- ["a.mini", "b.mini"] do
      Runtime.execute(db, :rows, file, fn db, file ->
        text = Runtime.input(db, :source_text, file)
        for i <- 1..50, do: [text, i, %{file: file}]
      end)
    end

    intern = Database.intern_table(db, :names)
    Enum.each(~w(alpha beta gamma), &Intern.intern(intern, &1))

    Database.register_entity(db, Roux.Test.ManifestEntity)
    [{_, tid}] = :ets.lookup(db.entity_registry, Roux.Test.ManifestEntity)
    :ets.insert(tid, {1, %{name: %{value: "foo", hash: 123, changed_at: 1}}, 0})
    db
  end

  # Registrations are not persisted: a run registers its inputs and
  # queries again. The queries here run as closures (`Runtime.execute/4`);
  # a registration is what lets a restore keep their entries.
  defp restored(path, queries \\ [:rows, :derived]) do
    {:ok, data} = Manifest.load(path)
    db = Database.new()
    Database.register_input(db, :source_text, durability: :medium)
    Database.register_input(db, :src, durability: :medium)
    Database.register_input(db, :stable, durability: :high)
    for name <- queries, do: register_closure(db, name)
    :ok = Manifest.restore(db, data)
    db
  end

  defp register_closure(db, name, version \\ nil) do
    Database.register_query(db, name, %{module: __MODULE__, function: name, code_version: version})
  end

  defp entity_rows(db) do
    [{_, tid}] = :ets.lookup(db.entity_registry, Roux.Test.ManifestEntity)
    :ets.tab2list(tid)
  end

  describe "persisted metadata" do
    test "a restored database holds what the written one held", %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")
      Manifest.write(populate(db), %{}, path)
      db2 = restored(path)

      try do
        assert Enum.sort(Memo.entries(db2)) == Enum.sort(Memo.entries(db))
        assert Revision.snapshot(db2.revision) == Revision.snapshot(db.revision)
        assert entity_rows(db2) == entity_rows(db)

        intern = Database.intern_table(db, :names)
        intern2 = Database.intern_table(db2, :names)

        for value <- ~w(alpha beta gamma) do
          assert Intern.lookup(intern2, value) == Intern.lookup(intern, value)
        end

        assert Intern.intern(intern2, "delta") == Intern.intern(intern, "delta")
      after
        Database.shutdown(db2)
      end
    end

    test "a restored database serves its entries without recomputing them", %{
      db: db,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "compile.roux")
      Manifest.write(populate(db), %{}, path)
      db2 = restored(path)

      try do
        # The same revision: validation passes, and the served value is
        # the persisted one, decoded on this first read.
        served =
          Runtime.execute(db2, :rows, "a.mini", fn _db, _file ->
            flunk("a restored entry was recomputed")
          end)

        assert {:ok, %Entry{value: ^served}} = Memo.get(db, {:rows, "a.mini"})

        # An input change recomputes what read it, and only that.
        Input.set(db2, :source_text, "a.mini", "changed")

        assert [["changed", 1, _] | _] =
                 Runtime.execute(db2, :rows, "a.mini", fn db, file ->
                   text = Runtime.input(db, :source_text, file)
                   for i <- 1..50, do: [text, i, %{file: file}]
                 end)

        assert [["beta", 1, _] | _] =
                 Runtime.execute(db2, :rows, "b.mini", fn _db, _file ->
                   flunk("an unaffected entry was recomputed")
                 end)
      after
        Database.shutdown(db2)
      end
    end

    test "restore leaves interned rows pending until the table is used", %{
      db: db,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "compile.roux")
      Manifest.write(populate(db), %{}, path)
      db2 = restored(path)

      try do
        intern2 = Database.intern_table(db2, :names)
        assert :ets.info(intern2.forward, :size) == 0
        assert Intern.size(intern2) == 3
      after
        Database.shutdown(db2)
      end
    end

    test "writing a restored database again reuses every unreplaced encoding", %{
      db: db,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "compile.roux")
      again = Path.join(tmp_dir, "again.roux")
      Manifest.write(populate(db), %{"a.mini" => %{mtime: 1, hash: 2}}, path)
      db2 = restored(path)

      try do
        # Read one value: reading decodes it but keeps the encoding.
        {:ok, _} = Memo.get(db2, {:rows, "a.mini"})
        Manifest.write(db2, %{"a.mini" => %{mtime: 1, hash: 2}}, again)

        {:ok, first} = Manifest.load(path)
        {:ok, second} = Manifest.load(again)
        assert Enum.sort(second.memo_entries) == Enum.sort(first.memo_entries)
        assert second.intern_data == first.intern_data
        assert second.sources == first.sources
      after
        Database.shutdown(db2)
      end
    end

    test "writes a recomputed entry's new value", %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")
      Manifest.write(populate(db), %{}, path)
      db2 = restored(path)

      try do
        Input.set(db2, :source_text, "a.mini", "changed")
        Runtime.execute(db2, :rows, "a.mini", fn _db, _file -> :recomputed end)
        Manifest.write(db2, %{}, path)

        db3 = restored(path)

        try do
          assert {:ok, %Entry{value: :recomputed}} = Memo.get(db3, {:rows, "a.mini"})
          assert {:ok, %Entry{value: "changed"}} = Memo.get(db3, {:input, :source_text, "a.mini"})
          assert Memo.get(db3, {:rows, "b.mini"}) == Memo.get(db, {:rows, "b.mini"})
        after
          Database.shutdown(db3)
        end
      after
        Database.shutdown(db2)
      end
    end

    test "leaves out the entries of queries no longer registered", %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")
      Manifest.write(populate(db), %{}, path)
      db2 = restored(path, [])

      try do
        assert Memo.get(db2, {:rows, "a.mini"}) == :miss
        assert {:ok, _} = Memo.get(db2, {:input, :source_text, "a.mini"})
      after
        Database.shutdown(db2)
      end
    end

    # :gone's body, dispatched by name (`register_closure/3` names this
    # module): a fan-out demands its members through the registry.
    def gone(db, key) do
      Runtime.execute(db, :gone, key, fn db, key -> Runtime.input(db, :source_text, key) end)
    end

    # A graph over an input: :gone reads it, :reader reads :gone, :top
    # reads :reader, :fan reads :gone through a fan-out, :other reads the
    # input alone. All registered when written; restored without :gone.
    defp gone_graph(db) do
      Database.register_input(db, :source_text, durability: :medium)
      Database.register_input(db, :stable, durability: :high)
      for name <- [:gone, :reader, :top, :fan, :other], do: register_closure(db, name)
      Input.set(db, :source_text, "a", "alpha")
      Input.set(db, :stable, :k, 1)

      Runtime.execute(db, :top, "a", fn db, key ->
        Runtime.execute(db, :reader, key, fn db, key -> gone(db, key) end)
      end)

      Runtime.execute(db, :fan, "a", fn db, key -> Runtime.parallel(db, [{:gone, key}]) end)

      Runtime.execute(db, :other, "a", fn db, key ->
        {Runtime.input(db, :source_text, key), Runtime.input(db, :stable, :k)}
      end)
    end

    test "leaves out every entry that read a query no longer registered, transitively",
         %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")
      gone_graph(db)
      Manifest.write(db, %{}, path)

      db2 = restored(path, [:reader, :top, :fan, :other])

      try do
        for query <- [:gone, :reader, :top, :fan] do
          assert Memo.get(db2, {query, "a"}) == :miss, "#{query} was restored"
        end

        assert {:ok, %Entry{value: {"alpha", 1}}} = Memo.get(db2, {:other, "a"})

        # Validation walks what was kept (a :high input moved) and never
        # meets an edge to a query nothing can run.
        Input.set(db2, :stable, :k, 2)

        assert Runtime.execute(db2, :other, "a", fn db, key ->
                 {Runtime.input(db, :source_text, key), Runtime.input(db, :stable, :k)}
               end) == {"alpha", 2}

        assert Runtime.execute(db2, :top, "a", fn _db, _key -> :recomputed end) == :recomputed
      after
        Database.shutdown(db2)
      end
    end

    test "an entry that read an unregistered query whose own entry was not kept goes too",
         %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")
      Database.register_input(db, :source_text, durability: :medium)
      register_closure(db, :reader)
      Input.set(db, :source_text, "a", "alpha")

      # :ephemeral is never registered: its entry is not restored, and
      # nothing could run it again.
      Runtime.execute(db, :reader, "a", fn db, key ->
        Runtime.execute(db, :ephemeral, key, fn db, key ->
          Runtime.input(db, :source_text, key)
        end)
      end)

      Manifest.write(db, %{}, path)
      db2 = restored(path, [:reader])

      try do
        assert Memo.get(db2, {:reader, "a"}) == :miss
        assert {:ok, _} = Memo.get(db2, {:input, :source_text, "a"})
      after
        Database.shutdown(db2)
      end
    end

    test "an entry of another code version re-executes; unchanged, its readers do not",
         %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")
      Database.register_input(db, :source_text, durability: :medium)
      register_closure(db, :len, "v1")
      register_closure(db, :parity)
      Input.set(db, :source_text, "a", "abcd")

      len = fn db, key -> db |> Runtime.input(:source_text, key) |> byte_size() end
      parity = fn db, key -> rem(Runtime.execute(db, :len, key, len), 2) end
      assert Runtime.execute(db, :parity, "a", parity) == 0
      Manifest.write(db, %{}, path)

      {:ok, data} = Manifest.load(path)
      db2 = Database.new()

      try do
        Database.register_input(db2, :source_text, durability: :medium)
        register_closure(db2, :len, "v2")
        register_closure(db2, :parity)
        :ok = Manifest.restore(db2, data)
        log = Roux.QueryLog.start(db2)

        # Another body, and the same value: :len re-runs, :parity is kept.
        len2 = fn db, key -> db |> Runtime.input(:source_text, key) |> String.length() end
        Process.put({Runtime, :query_fun, :len}, len2)

        assert Runtime.execute(db2, :parity, "a", fn _db, _key -> flunk("recomputed") end) ==
                 0

        assert Roux.QueryLog.executions(log, :len) == ["a"]
        assert Roux.QueryLog.cutoffs(log, :len) == ["a"]
        assert {:ok, entry} = Memo.get(db2, {:len, "a"})
        assert entry.code_version == "v2"
        Roux.QueryLog.stop(log)
      after
        Database.shutdown(db2)
      end
    end

    test "keeps no entry its query keeps nowhere, no transient one, and none that read one",
         %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")
      :ok = Roux.Lang.register_module(db, PersistQueries)
      Input.set(db, :psrc, "kept", 1)
      Input.set(db, :psrc, "gone", :lost)

      for key <- ["kept", "gone"] do
        PersistQueries.p_top(db, key)
        PersistQueries.p_none(db, key)
        PersistQueries.p_blob(db, key)
      end

      assert {:ok, %Entry{persist: :transient}} = Memo.get(db, {:p_fact, "gone"})
      assert {:ok, %Entry{persist: :inline}} = Memo.get(db, {:p_fact, "kept"})
      Manifest.write(db, %{}, path)

      {:ok, data} = Manifest.load(path)
      kept = data |> Manifest.memo_entries() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      for query <- [:p_fact, :p_reader, :p_top, :p_blob] do
        assert {query, "kept"} in kept
      end

      for key <- ["kept", "gone"], do: refute({:p_none, key} in kept)
      for query <- [:p_fact, :p_reader, :p_top], do: refute({query, "gone"} in kept)
      assert {:input, :psrc, "gone"} in kept

      # The next run asks again, from the fact up.
      db2 = Database.new()

      try do
        :ok = Roux.Lang.register_module(db2, Roux.Test.PersistQueries)
        :ok = Manifest.restore(db2, data)
        log = Roux.QueryLog.start(db2)
        PersistQueries.p_top(db2, "gone")
        PersistQueries.p_top(db2, "kept")
        assert Roux.QueryLog.executions(log, :p_fact) == ["gone"]
        assert Roux.QueryLog.executions(log, :p_top) == ["gone"]
        Roux.QueryLog.stop(log)
      after
        Database.shutdown(db2)
      end
    end

    property "write, load and restore reproduce any database" do
      check all(
              inputs <- map_of(string(:alphanumeric), term(), max_length: 15),
              derived <- map_of(term(), term(), max_length: 15),
              interned <- uniq_list_of(term(), max_length: 20)
            ) do
        tmp =
          Path.join(System.tmp_dir!(), "roux_manifest_prop_#{System.unique_integer([:positive])}")

        db = Database.new()

        try do
          Database.register_input(db, :src, durability: :medium)
          Enum.each(inputs, fn {key, value} -> Input.set(db, :src, key, value) end)

          Enum.each(derived, fn {key, value} ->
            Runtime.execute(db, :derived, key, fn _db, _key -> value end)
          end)

          intern = Database.intern_table(db, :values)
          Enum.each(interned, &Intern.intern(intern, &1))

          Manifest.write(db, %{}, tmp)
          db2 = restored(tmp)

          try do
            # Every entry, whichever the first read is.
            assert Enum.sort(Memo.entries(db2)) == Enum.sort(Memo.entries(db))
            assert Revision.snapshot(db2.revision) == Revision.snapshot(db.revision)

            intern2 = Database.intern_table(db2, :values)

            for value <- Enum.reverse(interned) do
              assert Intern.lookup(intern2, value) == Intern.lookup(intern, value)
            end

            assert Intern.size(intern2) == Intern.size(intern)
          after
            Database.shutdown(db2)
          end
        after
          Database.shutdown(db)
          File.rm(tmp)
        end
      end
    end
  end

  # -- values held by digest --

  describe "values held by digest" do
    setup %{tmp_dir: tmp_dir} do
      store = Blob.open!(Path.join(tmp_dir, "store"))
      db = Database.new(blob: store)
      :ok = Roux.Lang.register_module(db, PersistQueries)
      Input.set(db, :psrc, "a", %{rows: Enum.to_list(1..100)})
      Input.set(db, :psrc, "b", %{rows: [1]})
      PersistQueries.p_blob(db, "a")
      PersistQueries.p_blob(db, "b")
      PersistQueries.p_top(db, "a")
      path = Path.join(tmp_dir, "compile.roux")
      :ok = Manifest.write(db, %{}, path)
      on_exit(fn -> quietly(fn -> Database.shutdown(db) end) end)
      %{store: store, path: path, written: db}
    end

    defp quietly(fun) do
      fun.()
    catch
      :exit, _ -> :ok
    end

    defp restored_with(store, path) do
      {:ok, data} = Manifest.load(path)
      db = Database.new(blob: store)
      :ok = Roux.Lang.register_module(db, PersistQueries)
      :ok = Manifest.restore(db, data)
      db
    end

    defp held(path) do
      {:ok, data} = Manifest.load(path)

      for {{:p_blob, key}, _, _, _, _, _, _, {:blob, digest}, _, _} <- data.memo_entries,
          into: %{},
          do: {key, digest}
    end

    test "a :blob query's value is in the store, and the manifest holds its digest",
         %{store: store, path: path} do
      held = held(path)
      assert Map.keys(held) == ["a", "b"]
      assert {:ok, %{rows: rows}} = Blob.get_term(store, held["a"])
      assert rows == Enum.to_list(1..100)

      {:ok, data} = Manifest.load(path)
      entries = Manifest.memo_entries(data, store)

      assert {{:p_blob, "a"}, %Entry{value: %{rows: ^rows}, persist: :blob}} =
               List.keyfind(entries, {:p_blob, "a"}, 0)

      # Inline entries stay inline.
      assert Enum.any?(
               data.memo_entries,
               &match?({{:p_top, "a"}, _, _, _, _, _, _, bin, _, _} when is_binary(bin), &1)
             )
    end

    test "restored, a held value is read from the store when first read", %{
      store: store,
      path: path
    } do
      db = restored_with(store, path)

      try do
        assert {:ok, digest} = Memo.held_digest(db, {:p_blob, "a"})
        assert digest == held(path)["a"]
        assert %{rows: rows} = PersistQueries.p_blob(db, "a")
        assert length(rows) == 100
      after
        Database.shutdown(db)
      end
    end

    test "a missing blob is recomputed transparently, and keeps its changed_at", %{
      store: store,
      path: path
    } do
      digest = held(path)["a"]
      File.rm!(Blob.path(store, digest))
      db = restored_with(store, path)
      handler = {__MODULE__, make_ref()}
      me = self()

      :telemetry.attach(
        handler,
        [:roux, :blob, :missing],
        fn _event, _m, meta, _ -> send(me, {:missing, meta.query_name, meta.key}) end,
        nil
      )

      try do
        {:ok, before} = Memo.changed_at(db, {:p_blob, "a"})
        log = Roux.QueryLog.start(db)
        assert %{rows: _} = PersistQueries.p_blob(db, "a")
        assert_received {:missing, :p_blob, "a"}
        assert Roux.QueryLog.executions(log, :p_blob) == ["a"]
        assert {:ok, ^before} = Memo.changed_at(db, {:p_blob, "a"})
        Roux.QueryLog.stop(log)

        # Served from memory now, and written back to the store next time.
        :ok = Manifest.write(db, %{}, path)
        assert Blob.member?(store, digest)
      after
        :telemetry.detach(handler)
        Database.shutdown(db)
      end
    end

    test "early cutoff compares digests, putting a missing blob back", %{
      store: store,
      path: path
    } do
      digest = held(path)["b"]
      db = restored_with(store, path)

      try do
        File.rm!(Blob.path(store, digest))
        # Another key moves the revision; "b" is set to what it was.
        Input.set(db, :psrc, "b", %{rows: [2]})
        Input.set(db, :psrc, "b", %{rows: [1]})
        log = Roux.QueryLog.start(db)

        assert %{rows: [1]} = PersistQueries.p_blob(db, "b")
        assert Roux.QueryLog.cutoffs(log, :p_blob) == ["b"]
        assert {:ok, ^digest} = Memo.held_digest(db, {:p_blob, "b"})
        assert Blob.member?(store, digest)
        Roux.QueryLog.stop(log)
      after
        Database.shutdown(db)
      end
    end

    test "the manifest retains what it names, and a collection keeps it", %{
      store: store,
      path: path
    } do
      digests = path |> held() |> Map.values()
      old = System.os_time(:second) - 3 * 24 * 60 * 60
      for digest <- digests, do: File.touch!(Blob.path(store, digest), old)

      Blob.gc(store)
      assert Enum.all?(digests, &Blob.member?(store, &1))

      # Gone, and not retained for the grace period: its roots go.
      File.rm!(path)
      old = System.os_time(:second) - 3 * 24 * 60 * 60

      for root <- Path.wildcard(Path.join([store.root, "roots", "*"])),
          do: File.touch!(root, old)

      Blob.gc(store)
      refute Enum.any?(digests, &Blob.member?(store, &1))
    end

    test "without a store, values are written inline", %{written: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "inline.roux")
      :ok = Manifest.write(%{db | blob: nil}, %{}, path)
      assert held(path) == %{}
    end
  end

  describe "held blobs and code versions" do
    test "an entry's held digests are kept alive, and its code version with it",
         %{db: _db, tmp_dir: tmp_dir} do
      store = Blob.open!(Path.join(tmp_dir, "store"))
      db = Database.new(blob: store)
      {:ok, digest} = Blob.put(store, "a file the body wrote")
      register_closure(db, :holder, "v1")

      Runtime.execute(db, :holder, :k, fn _db, _key ->
        :ok = Runtime.hold(digest)
        {:file, digest}
      end)

      path = Path.join(tmp_dir, "compile.roux")
      :ok = Manifest.write(db, %{}, path)
      {:ok, data} = Manifest.load(path)
      [{{:holder, :k}, entry}] = Manifest.memo_entries(data)
      assert entry.blobs == [digest]
      assert entry.code_version == "v1"

      File.touch!(Blob.path(store, digest), System.os_time(:second) - 3 * 24 * 60 * 60)
      Blob.gc(store)
      assert Blob.member?(store, digest)

      # Restored under the same version, the entry is served as it was.
      db2 = Database.new(blob: store)
      register_closure(db2, :holder, "v1")
      :ok = Manifest.restore(db2, data)

      assert Runtime.execute(db2, :holder, :k, fn _, _ -> flunk("recomputed") end) ==
               {:file, digest}

      assert_raise ArgumentError, fn -> Runtime.hold(digest) end
      Database.shutdown(db)
      Database.shutdown(db2)
    end
  end

  describe "write/3 encodes in a process of its own" do
    test "leaves nothing in the mailbox of a caller that traps exits", %{
      db: db,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "compile.roux")
      populate(db)

      {:messages, messages} =
        Task.async(fn ->
          Process.flag(:trap_exit, true)
          :ok = Manifest.write(db, %{}, path)
          Process.info(self(), :messages)
        end)
        |> Task.await()

      assert messages == []
      assert {:ok, _} = Manifest.load(path)
    end

    test "raises what encoding raised, in the caller", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")
      gone = Database.new()
      Database.shutdown(gone)

      # The memo table is gone: reading it raises in the encoder.
      assert_raise ArgumentError, fn -> Manifest.write(gone, %{}, path) end
      refute File.exists?(path)
    end
  end

  # -- integrity --

  describe "integrity" do
    setup %{db: db, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "compile.roux")
      Manifest.write(populate(db), %{}, path)
      %{path: path, bytes: File.read!(path)}
    end

    @header_size 16

    test "the manifest it writes loads", %{path: path} do
      assert {:ok, %{vsn: 6}} = Manifest.load(path)
    end

    test "format 5 remains readable", %{path: path, bytes: bytes} do
      <<"ROUXMNFT", 6::32, rest::binary>> = bytes
      File.write!(path, ["ROUXMNFT", <<5::32>>, rest])
      assert {:ok, %{vsn: 5}} = Manifest.load(path)
    end

    test "refuses a manifest with any payload byte changed", %{path: path, bytes: bytes} do
      payload_size = byte_size(bytes) - @header_size

      for offset <- [0, div(payload_size, 3), div(payload_size, 2), payload_size - 1] do
        at = @header_size + offset
        <<before::binary-size(at), byte, rest::binary>> = bytes
        File.write!(path, [before, Bitwise.bxor(byte, 0x5A), rest])
        assert Manifest.load(path) == :error, "a change at payload byte #{offset} was read"
      end
    end

    test "refuses a truncated manifest", %{path: path, bytes: bytes} do
      for size <- [
            0,
            7,
            @header_size - 1,
            @header_size,
            div(byte_size(bytes), 2),
            byte_size(bytes) - 1
          ] do
        File.write!(path, binary_part(bytes, 0, size))
        assert Manifest.load(path) == :error, "a manifest cut to #{size} bytes was read"
      end
    end

    test "refuses another format, even with a good checksum", %{path: path, bytes: bytes} do
      <<magic::binary-size(8), 6::32, rest::binary>> = bytes

      for format <- [3, 4, 7] do
        File.write!(path, [magic, <<format::32>>, rest])
        assert Manifest.load(path) == :error
      end

      File.write!(path, ["ROUXMNFX", <<6::32>>, rest])
      assert Manifest.load(path) == :error
    end

    test "refuses a checksummed payload that is not manifest data", %{path: path} do
      {:ok, data} = Manifest.load(path)
      good = Map.delete(data, :vsn)
      [entry | entries] = good.memo_entries

      for payload <- [
            :not_a_manifest,
            Map.delete(good, :memo_entries),
            %{good | memo_entries: [put_elem(entry, 7, :not_encoded) | entries]},
            %{good | memo_entries: [put_elem(entry, 7, {:blob, :not_a_digest}) | entries]},
            %{good | memo_entries: [put_elem(entry, 8, :not_a_version) | entries]},
            %{good | memo_entries: [Tuple.delete_at(entry, 9) | entries]},
            %{good | memo_entries: [{:not, :an, :entry} | entries]},
            %{good | intern_data: [{:names, %{version: 2, forward: [], counter: 0}}]},
            %{good | revision: %{counter: -1, high: 0, medium: 0, low: 0}}
          ] do
        payload = :erlang.term_to_binary(payload)
        File.write!(path, ["ROUXMNFT", <<6::32, :erlang.crc32(payload)::32>>, payload])
        assert Manifest.load(path) == :error, "read #{inspect(payload, limit: 3)}"
      end
    end

    test "a write replaces the manifest whole and leaves nothing beside it", %{
      db: db,
      path: path,
      tmp_dir: tmp_dir
    } do
      Input.set(db, :source_text, "a.mini", "rewritten")
      Manifest.write(db, %{}, path)

      assert File.ls!(tmp_dir) == ["compile.roux"]
      db2 = restored(path)

      try do
        assert Input.get(db2, :source_text, "a.mini") == "rewritten"
      after
        Database.shutdown(db2)
      end
    end

    test "a write that fails leaves the old manifest in place", %{
      db: db,
      path: path,
      bytes: bytes,
      tmp_dir: tmp_dir
    } do
      Input.set(db, :source_text, "a.mini", "never written")
      File.chmod!(tmp_dir, 0o555)

      try do
        assert_raise File.Error, fn -> Manifest.write(db, %{}, path) end
      after
        File.chmod!(tmp_dir, 0o755)
      end

      assert File.read!(path) == bytes
      assert File.ls!(tmp_dir) == ["compile.roux"]
    end

    test "a write whose rename fails removes its temporary file", %{db: db, tmp_dir: tmp_dir} do
      # A non-empty directory where the manifest goes: the rename fails.
      target = Path.join(tmp_dir, "occupied")
      File.mkdir_p!(Path.join(target, "inside"))

      assert_raise File.RenameError, fn -> Manifest.write(db, %{}, target) end
      assert Enum.sort(File.ls!(tmp_dir)) == ["compile.roux", "occupied"]
    end
  end
end
