defmodule Roux.Test.TinyLang do
  @moduledoc false
  @behaviour Roux.Lang
  use Roux.Query

  @impl Roux.Lang
  def file_extensions, do: [".tiny"]

  @impl Roux.Lang
  def compile_query, do: :tiny_compile

  @impl Roux.Lang
  def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

  @impl Roux.Lang
  def module_interface(db, source_path) do
    # The module interface is whatever the compile query produces.
    Roux.Runtime.query(db, :tiny_compile, source_path)
  end

  definput :tiny_source, durability: :low

  defquery :tiny_compile, key: path do
    source = Roux.Runtime.input(db, :tiny_source, path)
    %{exports: [:main], compiled: source}
  end
end
