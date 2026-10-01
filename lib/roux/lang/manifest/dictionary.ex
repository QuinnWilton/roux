defmodule Roux.Lang.Manifest.Dictionary do
  @moduledoc false

  # Keys and dependency terms share IDs; long binary subterms (paths, digests)
  # share a second table. Values remain opaque ETF, ready for lazy restoration.
  @spec encode([tuple()]) :: tuple()
  def encode(entries) do
    context = {__MODULE__, make_ref()}
    Process.put(context, %{keys: %{}, terms: [], binaries: %{}, strings: []})

    try do
      rows = Enum.map(entries, &encode_row(&1, context))
      %{terms: terms, strings: strings} = Process.get(context)
      {:dictionary, Enum.reverse(strings), Enum.reverse(terms), rows}
    after
      Process.delete(context)
    end
  end

  defp encode_row(
         {key, hash, changed, verified, deps, durability, outputs, value, code, blobs},
         ctx
       ) do
    {intern_key(key, ctx), hash, changed, verified, Enum.map(deps, &intern_key(&1, ctx)),
     durability, share(outputs, ctx), share_value(value, ctx), share_code(code, ctx),
     share(blobs, ctx)}
  end

  defp intern_key(term, ctx) do
    case Process.get(ctx).keys do
      %{^term => id} ->
        id

      keys ->
        id = map_size(keys)
        encoded = share(term, ctx)
        state = Process.get(ctx)
        Process.put(ctx, %{state | keys: Map.put(keys, term, id), terms: [encoded | state.terms]})
        id
    end
  end

  defp intern_binary(binary, ctx) do
    state = Process.get(ctx)

    case state.binaries do
      %{^binary => id} ->
        id

      binaries ->
        id = map_size(binaries)

        Process.put(ctx, %{
          state
          | binaries: Map.put(binaries, binary, id),
            strings: [binary | state.strings]
        })

        id
    end
  end

  defp share_code(nil, _ctx), do: nil
  defp share_code(code, ctx), do: intern_binary(code, ctx)
  defp share_value(value, _ctx) when is_binary(value), do: value
  defp share_value(value, ctx), do: share(value, ctx)

  defp share(binary, ctx) when is_binary(binary) and byte_size(binary) >= 16,
    do: {:roux_binary, intern_binary(binary, ctx)}

  # Escape user tuples that could otherwise be mistaken for codec markers.
  defp share({tag, _} = tuple, ctx) when tag in [:roux_binary, :roux_tuple],
    do: {:roux_tuple, tuple |> Tuple.to_list() |> Enum.map(&share(&1, ctx))}

  defp share(tuple, ctx) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&share(&1, ctx)) |> List.to_tuple()

  defp share([head | tail], ctx), do: [share(head, ctx) | share(tail, ctx)]

  defp share(map, ctx) when is_map(map),
    do: Map.new(:maps.to_list(map), fn {k, v} -> {share(k, ctx), share(v, ctx)} end)

  defp share(term, _ctx), do: term

  @spec decode(term()) :: {:ok, [tuple()]} | :error
  def decode({:dictionary, strings, terms, rows})
      when is_list(strings) and is_list(terms) and is_list(rows) do
    if Enum.all?(strings, &is_binary/1) do
      strings = List.to_tuple(strings)
      keys = terms |> Enum.map(&expand(&1, strings)) |> List.to_tuple()
      {:ok, Enum.map(rows, &decode_row(&1, keys, strings))}
    else
      :error
    end
  rescue
    _ in [ArgumentError, FunctionClauseError, MatchError] -> :error
  end

  def decode(_), do: :error

  defp decode_row(
         {key, hash, changed, verified, deps, durability, outputs, value, code, blobs},
         keys,
         strings
       )
       when is_list(deps) do
    code = if code == nil, do: nil, else: reference(strings, code)
    value = if is_binary(value), do: value, else: expand(value, strings)

    {reference(keys, key), hash, changed, verified, Enum.map(deps, &reference(keys, &1)),
     durability, expand(outputs, strings), value, code, expand(blobs, strings)}
  end

  defp reference(table, id) when is_integer(id) and id >= 0, do: elem(table, id)

  defp expand({:roux_binary, id}, strings), do: reference(strings, id)

  defp expand({:roux_tuple, items}, strings) when is_list(items),
    do: items |> Enum.map(&expand(&1, strings)) |> List.to_tuple()

  defp expand({:roux_tuple, _}, _strings), do: raise(ArgumentError, "invalid tuple escape")

  defp expand(tuple, strings) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&expand(&1, strings)) |> List.to_tuple()

  defp expand([head | tail], strings), do: [expand(head, strings) | expand(tail, strings)]

  defp expand(map, strings) when is_map(map),
    do: Map.new(:maps.to_list(map), fn {k, v} -> {expand(k, strings), expand(v, strings)} end)

  defp expand(term, _strings), do: term
end
