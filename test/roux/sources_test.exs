defmodule Roux.SourcesTest do
  use ExUnit.Case, async: true

  alias Roux.{Database, Input, Sources}

  @moduletag :tmp_dir

  setup do
    db = Database.new()
    Database.register_input(db, :file, durability: :medium)
    on_exit(fn -> quietly(fn -> Database.shutdown(db) end) end)
    %{db: db}
  end

  defp quietly(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  # A file written long enough ago that its stamp is trusted.
  defp write!(path, content, age \\ 60) do
    File.write!(path, content)
    File.touch!(path, System.os_time(:second) - age)
    path
  end

  test "reads new files, then skips the ones whose stamp held", %{db: db, tmp_dir: tmp} do
    a = write!(Path.join(tmp, "a"), "alpha")
    b = write!(Path.join(tmp, "b"), "beta")

    first = Sources.sync(db, :file, %{a: a, b: b}, %{})
    assert first.changed == [:a, :b]
    assert first.removed == []
    assert %{mtime: _, size: 5, hash: hash} = first.meta[a]
    assert hash == :erlang.md5("alpha")
    assert Input.get(db, :file, :a) == %{path: a, hash: hash}

    # Unreadable, yet not read: its stamp matches. (`File.chmod!/2` moves
    # the modification time too: set back.)
    File.chmod!(a, 0o000)
    File.touch!(a, first.meta[a].mtime)

    try do
      second = Sources.sync(db, :file, %{a: a, b: b}, first.meta)
      assert second.changed == []
      assert second.meta == first.meta
    after
      File.chmod!(a, 0o644)
    end
  end

  test "a changed file is changed; a touch with the same content is not", %{
    db: db,
    tmp_dir: tmp
  } do
    a = write!(Path.join(tmp, "a"), "alpha")
    first = Sources.sync(db, :file, %{a: a}, %{})

    write!(a, "alpha", 30)
    touched = Sources.sync(db, :file, %{a: a}, first.meta)
    assert touched.changed == []
    assert touched.meta[a].mtime != first.meta[a].mtime

    write!(a, "omega", 20)
    assert %{changed: [:a]} = Sources.sync(db, :file, %{a: a}, touched.meta)
  end

  test "a file written moments ago is read whatever its stamp says", %{db: db, tmp_dir: tmp} do
    a = Path.join(tmp, "a")
    File.write!(a, "one")
    first = Sources.sync(db, :file, %{a: a}, %{})

    # Same size, and — within the second — the same mtime.
    File.write!(a, "two")
    File.touch!(a, first.meta[a].mtime)
    assert %{changed: [:a]} = Sources.sync(db, :file, %{a: a}, first.meta)
  end

  test "removes the keys whose files are gone", %{db: db, tmp_dir: tmp} do
    a = write!(Path.join(tmp, "a"), "alpha")
    b = write!(Path.join(tmp, "b"), "beta")
    first = Sources.sync(db, :file, %{a: a, b: b}, %{})

    File.rm!(b)
    result = Sources.sync(db, :file, %{a: a, b: b}, first.meta)
    assert result.removed == [:b]
    assert Map.keys(result.meta) == [a]
    refute Input.exists?(db, :file, :b)

    assert %{removed: [:a]} = Sources.sync(db, :file, %{}, result.meta)
  end

  test "hashes and values as told", %{db: db, tmp_dir: tmp} do
    a = write!(Path.join(tmp, "a"), "Alpha")

    result =
      Sources.sync(db, :file, %{a: a}, %{},
        hash: &String.downcase/1,
        value: fn %{content: content, hash: hash} -> {content, hash} end
      )

    assert result.meta[a].hash == "alpha"
    assert Input.get(db, :file, :a) == {"Alpha", "alpha"}
  end
end
