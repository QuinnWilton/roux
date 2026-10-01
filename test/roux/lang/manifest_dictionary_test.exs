defmodule Roux.Lang.ManifestDictionaryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.Lang.Manifest
  alias Roux.Lang.Manifest.Dictionary

  @moduletag :tmp_dir

  property "arbitrary keys and dependencies round-trip with exact term equality" do
    check all(keys <- list_of(term(), max_length: 30)) do
      entries = Enum.map(keys, &row(&1, keys))

      assert {:ok, decoded} =
               entries
               |> Dictionary.encode()
               |> :erlang.term_to_binary()
               |> :erlang.binary_to_term()
               |> Dictionary.decode()

      assert decoded === entries
    end
  end

  test "marker-shaped keys, maps, improper lists and numeric types remain distinct" do
    text = String.duplicate("shared", 20)

    keys = [
      1,
      1.0,
      {:roux_binary, 0},
      {:roux_tuple, [1, text]},
      [text | :tail],
      %{1 => text, 1.0 => {:roux_binary, 0}},
      {{:roux_tuple, [text]}, {:roux_binary, text}}
    ]

    entries = Enum.map(keys, &row(&1, keys))
    assert Dictionary.decode(Dictionary.encode(entries)) === {:ok, entries}
  end

  test "repeated graph terms are shared without touching inline value encodings" do
    path = String.duplicate("a/path/", 30)
    keys = for n <- 1..100, do: {:query, {path, n}}
    entries = Enum.map(keys, &row(&1, keys))
    encoded = Dictionary.encode(entries)
    assert :erlang.external_size(encoded) < div(:erlang.external_size(entries), 4)
    assert Dictionary.decode(encoded) === {:ok, entries}
  end

  test "invalid dictionary references and shapes reject the complete manifest", %{tmp_dir: dir} do
    {:dictionary, strings, keys, [entry]} = Dictionary.encode([row(:key, [:key])])

    invalid = [
      {:dictionary, strings, keys, [put_elem(entry, 0, -1)]},
      {:dictionary, strings, keys, [put_elem(entry, 4, [99_999])]},
      {:dictionary, strings, keys, [put_elem(entry, 4, :bad)]},
      {:dictionary, [:not_binary], keys, [entry]},
      {:dictionary, [], [{:roux_binary, 0}], [entry]},
      {:dictionary, [], [{:roux_tuple, :bad}], [entry]},
      {:dictionary, strings, keys, [:bad]},
      [:old_format_rows]
    ]

    for dictionary <- invalid do
      data = %{
        memo_entries: dictionary,
        sources: %{},
        entity_data: [],
        intern_data: [],
        revision: %{counter: 0, high: 0, medium: 0, low: 0}
      }

      payload = :erlang.term_to_binary(data)
      path = Path.join(dir, "manifest")
      File.write!(path, ["ROUXMNFT", <<8::32, :erlang.crc32(payload)::32>>, payload])
      assert Manifest.load(path) == :error
    end
  end

  defp row(key, deps) do
    {key, 42, 1, 2, deps, :medium, [{__MODULE__, key}], :erlang.term_to_binary({:ok, key}),
     String.duplicate("code", 8), [String.duplicate("a", 64)]}
  end
end
