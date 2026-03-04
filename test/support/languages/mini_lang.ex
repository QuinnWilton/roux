defmodule Roux.Test.MiniLang do
  @moduledoc false
  @behaviour Roux.Lang
  use Roux.Query

  @impl Roux.Lang
  def file_extensions, do: [".mini"]

  @impl Roux.Lang
  def compile_query, do: :mini_compile

  @impl Roux.Lang
  def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

  definput :source_text, durability: :low

  defquery :mini_parse, key: path do
    Roux.Runtime.input(db, :source_text, path)
  end

  defquery :mini_compile, key: path do
    ast = Roux.Runtime.query(db, :mini_parse, path)
    {:compiled, ast}
  end
end
