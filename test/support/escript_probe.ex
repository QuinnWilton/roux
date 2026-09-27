defmodule Roux.Test.EscriptProbe do
  @moduledoc false
  # The main module of the escripts `Roux.CodeEscriptTest` builds: what
  # `Roux.Code` makes of modules living in an escript's archive, reported
  # on stdout as a Base64 external term. Runs in the escript's own VM.

  # An escript's arguments are charlists.
  def main(args) do
    [store_root | roots] = Enum.map(args, &List.to_string/1)
    {:ok, _} = Application.ensure_all_started(:elixir)
    roots = Enum.map(roots, &String.to_atom/1)
    store = Roux.Blob.open!(store_root)

    # Every read of object code the digest makes: none, when a trace
    # over the escript's stamp vouches for it.
    :erlang.trace_pattern({:code, :get_object_code, 1}, true, [:call_count])
    digest = Roux.Code.digest(roots, store: store)
    {:call_count, reads} = :erlang.trace_info({:code, :get_object_code, 1}, :call_count)
    :erlang.trace_pattern({:code, :get_object_code, 1}, false, [:call_count])

    report = %{
      digest: digest,
      reads: reads,
      closure: Roux.Code.closure(roots),
      runtime: Roux.Code.runtime_version(),
      elixir_lib_dir: List.to_string(:code.lib_dir(:elixir))
    }

    IO.write(report |> :erlang.term_to_binary() |> Base.encode64())
  end
end
