defmodule Roux.Memo.Value do
  @moduledoc false

  alias Roux.Blob

  @type t :: binary() | {:blob, Blob.digest()} | packed()
  @type packed ::
          {:packed, Blob.digest(), Blob.digest(), non_neg_integer(), pos_integer()}

  @spec valid?(term()) :: boolean()
  def valid?(bytes) when is_binary(bytes), do: true
  def valid?({:blob, digest}), do: digest?(digest)

  def valid?({:packed, logical, physical, offset, length}) do
    digest?(logical) and digest?(physical) and is_integer(offset) and offset >= 0 and
      is_integer(length) and length > 0 and offset + length <= 0x7FFFFFFFFFFFFFFF
  end

  def valid?(_), do: false

  @spec logical_digest(term()) :: Blob.digest() | nil
  def logical_digest({:blob, digest}), do: digest
  def logical_digest({:packed, logical, _, _, _}), do: logical
  def logical_digest(_), do: nil

  @spec roots(term()) :: [Blob.digest()]
  def roots({:blob, digest}), do: [digest]
  def roots({:packed, _, physical, _, _}), do: [physical]
  def roots(_), do: []

  @spec load_bytes(Blob.t() | nil, t()) :: {:ok, binary()} | :miss
  def load_bytes(_, bytes) when is_binary(bytes), do: {:ok, bytes}
  def load_bytes(%Blob{} = store, {:blob, digest}), do: Blob.get(store, digest)

  def load_bytes(%Blob{} = store, {:packed, logical, physical, offset, length}) do
    Blob.get_slice(store, physical, offset, length, logical)
  end

  def load_bytes(_, _), do: :miss

  defp digest?(digest) when is_binary(digest) and byte_size(digest) == 64 do
    digest |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))
  end

  defp digest?(_), do: false
end
