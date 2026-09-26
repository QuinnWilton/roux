defmodule Roux.StampTest do
  use ExUnit.Case, async: true

  alias Roux.{Blob, Stamp}

  @moduletag :tmp_dir

  defp write!(path, content, age \\ 60) do
    File.write!(path, content)
    File.touch!(path, System.os_time(:second) - age)
    path
  end

  defp counting(value) do
    counter = :counters.new(1, [])

    {fn ->
       :counters.add(counter, 1, 1)
       value
     end, fn -> :counters.get(counter, 1) end}
  end

  test "computes once while the files' stamps hold", %{tmp_dir: tmp} do
    file = write!(Path.join(tmp, "bin"), "v1")
    key = {:version, make_ref()}
    {compute, runs} = counting({:ok, "1.0"})

    assert Stamp.memo(key, [file], compute) == {:ok, "1.0"}
    assert Stamp.memo(key, [file], compute) == {:ok, "1.0"}
    assert runs.() == 1

    write!(file, "v2", 30)
    assert Stamp.memo(key, [file], compute) == {:ok, "1.0"}
    assert runs.() == 2
  end

  test "a fresh VM reads the value from the store", %{tmp_dir: tmp} do
    file = write!(Path.join(tmp, "bin"), "v1")
    store = Blob.open!(Path.join(tmp, "store"))
    key = {:version, make_ref()}
    {compute, runs} = counting({:ok, "kept"})

    assert Stamp.memo(key, [file], compute, store: store) == {:ok, "kept"}
    :ok = Stamp.forget()
    assert Stamp.memo(key, [file], compute, store: store) == {:ok, "kept"}
    assert runs.() == 1
  end

  test "keeps nothing over a file written moments ago, nor an error", %{tmp_dir: tmp} do
    young = Path.join(tmp, "young")
    File.write!(young, "now")
    old = write!(Path.join(tmp, "old"), "then")
    {compute, runs} = counting(:value)
    {failing, fails} = counting({:error, :no})
    key = {:young, make_ref()}

    Stamp.memo(key, [young], compute)
    Stamp.memo(key, [young], compute)
    assert runs.() == 2

    key = {:failing, make_ref()}
    Stamp.memo(key, [old], failing)
    Stamp.memo(key, [old], failing)
    assert fails.() == 2
  end

  test "an absent file is a stamp like any other", %{tmp_dir: tmp} do
    missing = Path.join(tmp, "missing")
    key = {:absent, make_ref()}
    {compute, runs} = counting(:none)

    assert Stamp.memo(key, [missing], compute) == :none
    assert Stamp.memo(key, [missing], compute) == :none
    assert runs.() == 1
    assert Stamp.stamp(missing) == :absent

    write!(missing, "here now")
    Stamp.memo(key, [missing], compute)
    assert runs.() == 2
  end
end
