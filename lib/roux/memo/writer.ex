defmodule Roux.Memo.Writer do
  @moduledoc false

  alias Roux.Blob
  alias Roux.Memo.Value

  @header "RXMPACK1"
  @max_bytes 1024 * 1024
  @max_records 1024
  @compact_budget 4 * @max_bytes
  @compact_packs 4

  @type encoding :: {:term, Blob.digest(), binary()} | {:inline, binary()} | nil
  @type pending :: {:pending, Blob.digest()} | :missing
  @type publisher :: (encoding(), Value.t() | nil -> Value.t() | pending())

  # The state lives only in Manifest's isolated encoder. This lets its existing
  # memo fold emit placeholders while bounded batches are published incrementally.
  @spec run(Blob.t() | nil, Blob.t() | nil, (publisher() -> [tuple()])) :: [tuple()]
  def run(target, source, fun) do
    key = {__MODULE__, make_ref()}

    Process.put(key, %{
      target: target,
      source: source,
      pending: [],
      bytes: byte_size(@header),
      count: 0,
      handles: %{},
      sizes: %{}
    })

    try do
      entries = fun.(fn encoding, existing -> publish(key, encoding, existing) end)
      entries = compact(key, entries)
      flush(key)
      handles = Process.get(key).handles

      Enum.map(entries, fn entry ->
        case elem(entry, 7) do
          {:pending, digest} -> put_elem(entry, 7, Map.fetch!(handles, digest))
          _ -> entry
        end
      end)
    after
      Process.delete(key)
    end
  end

  defp publish(_key, {:inline, bytes}, _existing), do: bytes

  defp publish(key, {:term, digest, bytes}, existing) do
    state = Process.get(key)

    cond do
      state.target == nil -> bytes
      Value.logical_digest(existing) == digest and reusable?(key, existing) -> existing
      true -> enqueue(key, digest, bytes)
    end
  end

  defp publish(_key, nil, existing) when is_binary(existing), do: existing

  defp publish(key, nil, existing) do
    if reusable?(key, existing) do
      existing
    else
      case Value.load_bytes(Process.get(key).source, existing) do
        {:ok, bytes} ->
          if Process.get(key).target do
            enqueue(key, Value.logical_digest(existing), bytes)
          else
            bytes
          end

        :miss ->
          :missing
      end
    end
  end

  defp reusable?(key, handle) do
    %{source: source, target: target} = Process.get(key)

    if same_store?(source, target) do
      case handle do
        {:blob, digest} ->
          is_integer(size(key, digest))

        {:packed, _, digest, offset, length} ->
          case size(key, digest) do
            n when is_integer(n) -> n >= offset + length
            :missing -> false
          end

        _ ->
          false
      end
    else
      false
    end
  end

  defp same_store?(%Blob{root: a}, %Blob{root: b}), do: a == b
  defp same_store?(_, _), do: false

  # A reused physical file is refreshed once per checkpoint, even when hundreds
  # of records name it. Integrity remains checked by each lazy value read.
  defp size(key, digest) do
    state = Process.get(key)

    case state.sizes do
      %{^digest => size} ->
        size

      _ ->
        size =
          case Blob.keep(state.target, digest) do
            {:ok, size} -> size
            :miss -> :missing
          end

        Process.put(key, %{state | sizes: Map.put(state.sizes, digest, size)})
        size
    end
  end

  defp enqueue(key, digest, bytes) do
    state = Process.get(key)

    case state.handles do
      %{^digest => handle} ->
        handle

      _ ->
        if byte_size(bytes) + byte_size(@header) > @max_bytes do
          handle = loose(state.target, digest, bytes)
          Process.put(key, %{state | handles: Map.put(state.handles, digest, handle)})
          handle
        else
          if state.bytes + byte_size(bytes) > @max_bytes or state.count >= @max_records,
            do: flush(key)

          state = Process.get(key)
          handle = {:pending, digest}

          Process.put(key, %{
            state
            | pending: [{digest, bytes} | state.pending],
              bytes: state.bytes + byte_size(bytes),
              count: state.count + 1,
              handles: Map.put(state.handles, digest, handle)
          })

          handle
        end
    end
  end

  defp flush(key) do
    case Process.get(key) do
      %{pending: []} ->
        :ok

      %{pending: [{digest, bytes}]} = state ->
        handle = loose(state.target, digest, bytes)
        reset(key, state, [{digest, handle}])

      state ->
        records = Enum.reverse(state.pending)
        bytes = IO.iodata_to_binary([@header | Enum.map(records, &elem(&1, 1))])
        physical = Blob.digest(bytes)

        handles =
          case Blob.put_encoded_term(state.target, physical, bytes) do
            {:ok, ^physical} ->
              {handles, _} =
                Enum.map_reduce(records, byte_size(@header), fn {logical, bytes}, offset ->
                  {{logical, {:packed, logical, physical, offset, byte_size(bytes)}},
                   offset + byte_size(bytes)}
                end)

              handles

            {:error, _} ->
              # Each record is already an ETF value; inline fallback needs no decode.
              records
          end

        reset(key, state, handles)
    end
  end

  defp reset(key, state, handles) do
    Process.put(key, %{
      state
      | pending: [],
        bytes: byte_size(@header),
        count: 0,
        handles: Map.merge(state.handles, Map.new(handles))
    })

    :ok
  end

  defp loose(store, digest, bytes) do
    case Blob.put_encoded_term(store, digest, bytes) do
      {:ok, ^digest} -> {:blob, digest}
      {:error, _} -> bytes
    end
  end

  # Reusing locators avoids rewriting unchanged packs, but sparse packs would
  # otherwise pin obsolete neighbors forever. Move at most four MiB per save.
  defp compact(key, entries) do
    groups =
      Enum.reduce(entries, %{}, fn entry, groups ->
        case elem(entry, 7) do
          {:packed, logical, physical, _, length} = handle ->
            Map.update(
              groups,
              physical,
              %{logical => {handle, length}},
              &Map.put(&1, logical, {handle, length})
            )

          _ ->
            groups
        end
      end)

    {selected, _budget} =
      groups
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({MapSet.new(), @compact_budget}, fn {physical, records},
                                                         {selected, budget} ->
        live = Enum.sum(for {_logical, {_handle, length}} <- records, do: length)

        case size(key, physical) do
          n when is_integer(n) and live * 2 < n and live <= budget ->
            if MapSet.size(selected) < @compact_packs,
              do: {MapSet.put(selected, physical), budget - live},
              else: {selected, budget}

          _ ->
            {selected, budget}
        end
      end)

    Enum.map(entries, fn entry ->
      case elem(entry, 7) do
        {:packed, logical, physical, _, _} = handle ->
          if MapSet.member?(selected, physical) do
            encoded =
              case Value.load_bytes(Process.get(key).target, handle) do
                {:ok, bytes} -> enqueue(key, logical, bytes)
                :miss -> :missing
              end

            put_elem(entry, 7, encoded)
          else
            entry
          end

        _ ->
          entry
      end
    end)
  end
end
