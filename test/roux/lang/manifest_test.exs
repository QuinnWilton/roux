defmodule Roux.Lang.ManifestTest do
  use ExUnit.Case, async: true

  alias Roux.{Database, Input, Intern, Memo, Revision}
  alias Roux.Lang.Manifest
  alias Roux.Memo.Entry

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

    test "returns :error for wrong version", %{tmp_dir: tmp_dir} do
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
end
