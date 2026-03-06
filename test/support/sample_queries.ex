defmodule Roux.Test.SampleQueries do
  @moduledoc false
  use Roux.Query

  defentity(Roux.Test.SampleEntity)

  definput :source_text, durability: :low
  definput :config, durability: :high
  definput :events

  defquery :parse, key: file_path do
    {db, file_path}
  end

  defquery :typecheck, key: {file_path, opts} do
    {db, file_path, opts}
  end
end
