defmodule Roux.Test.HoverLang do
  @moduledoc false
  @behaviour Roux.Lang
  use Roux.Query

  @impl Roux.Lang
  def file_extensions, do: [".hover"]

  @impl Roux.Lang
  def compile_query, do: :hover_compile

  @impl Roux.Lang
  def diagnostics_query, do: :hover_diagnostics

  @impl Roux.Lang
  def hover_query, do: :hover_info

  @impl Roux.Lang
  def completions_query, do: :hover_completions

  @impl Roux.Lang
  def definition_query, do: :hover_definition

  @impl Roux.Lang
  def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

  definput :source_text, durability: :low

  defquery :hover_compile, key: uri do
    Roux.Runtime.input(db, :source_text, uri)
  end

  defquery :hover_diagnostics, key: uri do
    source = Roux.Runtime.input(db, :source_text, uri)

    cond do
      String.contains?(source, "error") ->
        [%{message: "found error in source", line: 1, column: 1, severity: :error}]

      String.contains?(source, "warning") ->
        [%{message: "found warning in source", line: 1, column: 1, severity: :warning}]

      true ->
        []
    end
  end

  defquery :hover_completions, key: {uri, position} do
    source = Roux.Runtime.input(db, :source_text, uri)
    {_line, _col} = position

    source
    |> String.split()
    |> Enum.map(fn word -> %{label: word, detail: "word from source"} end)
  end

  defquery :hover_info, key: {uri, position} do
    source = Roux.Runtime.input(db, :source_text, uri)
    {line, col} = position
    "Hover info for: #{String.trim(source)} at #{line}:#{col}"
  end

  defquery :hover_definition, key: {uri, position} do
    _source = Roux.Runtime.input(db, :source_text, uri)
    _ = position
    %{uri: uri, line: 1, column: 1}
  end
end
