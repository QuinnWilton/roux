defmodule Roux.Test.FailingLang do
  @moduledoc false
  @behaviour Roux.Lang
  use Roux.Query

  @impl Roux.Lang
  def file_extensions, do: [".fail"]

  @impl Roux.Lang
  def compile_query, do: :failing_compile

  @impl Roux.Lang
  def hover_query, do: :failing_hover

  @impl Roux.Lang
  def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

  definput :source_text, durability: :low

  defquery :failing_compile, key: path do
    _source = Roux.Runtime.input(db, :source_text, path)
    raise "compilation failed for #{path}"
  end

  defquery :failing_hover, key: {uri, position} do
    _source = Roux.Runtime.input(db, :source_text, uri)
    _ = position
    raise "hover failed"
  end
end
