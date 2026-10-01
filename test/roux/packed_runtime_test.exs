defmodule Roux.PackedRuntimeTest do
  use ExUnit.Case, async: true

  alias Roux.{Blob, Database, Input, Memo, Revision, Runtime}
  alias Roux.Lang.Manifest

  @moduletag :tmp_dir

  for damage <- [:missing, :corrupt], trigger <- [:dependency, :demand, :policy] do
    test "#{damage} packed value is repaired after #{trigger} without losing early cutoff", %{
      tmp_dir: dir
    } do
      store = Blob.open!(Path.join(dir, "store"))
      db = Database.new(blob: store)
      on_exit(fn -> stop(db) end)
      Input.register(db, Input.define(:source))

      Database.register_query(db, :rows, %{
        store: :blob,
        revalidate: if(unquote(trigger) == :policy, do: :execute)
      })

      Input.set(db, :source, :all, 1)
      value = %{rows: Enum.map(1..30, &{"row", &1})}

      query = fn db, key ->
        Runtime.input(db, :source, key)
        value
      end

      assert Runtime.execute(db, :rows, :all, query) == value
      {:ok, changed_at} = Memo.changed_at(db, {:rows, :all})
      {logical, encoded} = Blob.encode_term(value)
      header = "test-pack"
      {:ok, physical} = Blob.put(store, header <> encoded)
      locator = {:packed, logical, physical, byte_size(header), byte_size(encoded)}

      persisted =
        db
        |> Memo.persisted(fn _, _ -> true end)
        |> Enum.map(fn entry ->
          if elem(entry, 0) == {:rows, :all}, do: put_elem(entry, 7, locator), else: entry
        end)

      Memo.restore_persisted(db, persisted)
      assert Memo.held_locator(db, {:rows, :all}) == {:ok, locator}

      case unquote(damage) do
        :missing ->
          File.rm!(Blob.path(store, physical))

        :corrupt ->
          File.chmod!(Blob.path(store, physical), 0o644)

          File.write!(
            Blob.path(store, physical),
            header <> :binary.copy(<<0>>, byte_size(encoded))
          )
      end

      if unquote(trigger) == :dependency, do: Input.set(db, :source, :all, 2)
      writes = Database.writes(db)
      assert Runtime.execute(db, :rows, :all, query) == value
      assert Database.writes(db) > writes
      assert Memo.changed_at(db, {:rows, :all}) == {:ok, changed_at}
      assert Memo.held_locator(db, {:rows, :all}) == :none
      Runtime.drop_cached_values(db)
      assert Memo.fetch_value(db, {:rows, :all}) == {:ok, value}

      path = Path.join(dir, "manifest")
      assert Manifest.write(db, %{}, path) == :ok
      assert {:ok, manifest} = Manifest.load(path)
      retained = Enum.find(manifest.memo_entries, &(elem(&1, 0) == {:rows, :all}))
      refute elem(retained, 7) == locator

      next = Database.new(blob: store)

      try do
        Input.register(next, Input.define(:source))
        Database.register_query(next, :rows, %{store: :blob})
        Manifest.restore(next, manifest)

        assert Runtime.execute(next, :rows, :all, fn _, _ ->
                 flunk("repaired value recomputed")
               end) == value

        assert Memo.changed_at(next, {:rows, :all}) == {:ok, changed_at}
        assert Revision.current(next.revision) == Revision.current(db.revision)
      after
        Database.shutdown(next)
      end
    end
  end

  defp stop(db) do
    Database.shutdown(db)
  catch
    :exit, _ -> :ok
  end
end
