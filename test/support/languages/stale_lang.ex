defmodule Roux.Test.StaleLang do
  @moduledoc false
  # A language as roux 0.1 compiled it: no format stamp, and definitions
  # of the struct's old shape, without the code version, store and
  # transient fields a roux of format 1 reads. Its query raises: nothing
  # of it may run.
  @behaviour Roux.Lang

  @impl Roux.Lang
  def file_extensions, do: [".stale"]

  @impl Roux.Lang
  def compile_query, do: :stale_compile

  @impl Roux.Lang
  def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

  def stale_compile(db, path) do
    Roux.Runtime.execute(db, :stale_compile, path, fn _db, _path ->
      raise "a module compiled against another roux ran"
    end)
  end

  def __roux_queries__ do
    %{
      queries: [
        Map.drop(
          %Roux.Query.Definition{
            name: :stale_compile,
            module: __MODULE__,
            function: :stale_compile
          },
          [:code, :version, :store, :transient]
        )
      ],
      inputs: [%Roux.Input.Definition{name: :source_text, durability: :low}],
      entities: []
    }
  end
end

defmodule Roux.Test.FutureQueries do
  @moduledoc false
  # Queries compiled against a roux of a newer definition format.

  def __roux_queries__, do: %{queries: [], inputs: [], entities: [], code: nil}

  def __roux_format__, do: Roux.Query.format() + 1
end
