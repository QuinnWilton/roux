defmodule Roux.Stamp do
  @moduledoc """
  A value computed from files, kept for as long as the files' stat
  stamps say they have not changed: `memo/4`.

      Roux.Stamp.memo({:solver_version, bin}, [bin], fn -> version_of(bin) end, store: store)

  A stamp is a file's size, modification time, inode and change time
  (or its absence). The value is kept per VM, and — with `store:` — in a
  `Roux.Blob` store's action cache under the key and the stamps, so a
  fresh VM whose files have not moved reads it back instead of
  computing it. A value computed while a file was written within the
  last `recent:` seconds is not kept: a stamp that young may not show a
  write that follows it within the same second. Neither is `:error` or
  `{:error, _}`.
  """

  alias Roux.Blob

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @doc """
  The value `compute` gives from `files`, kept under `key` while the
  files' stamps hold (see the moduledoc).

  ## Options

    * `:store` — a `Roux.Blob` store to keep the value in across VMs;
    * `:recent` — seconds within which a file's stamp is not trusted
      (default 2).
  """
  @spec memo(term(), [Path.t()], (-> value), keyword()) :: value when value: var
  def memo(key, files, compute, opts \\ []) when is_list(files) and is_function(compute, 0) do
    opts = Keyword.validate!(opts, store: nil, recent: 2)
    stamps = Enum.map(files, &stamp/1)
    cutoff = System.os_time(:second) - Keyword.fetch!(opts, :recent)
    trusted? = Enum.all?(stamps, &trusted?(&1, cutoff))
    memo_key = {__MODULE__, key}

    case :persistent_term.get(memo_key, nil) do
      {^stamps, value} when trusted? ->
        value

      _other ->
        store = Keyword.fetch!(opts, :store)
        kept = {__MODULE__, key, stamps}

        case trusted? and store != nil and Blob.recall(store, kept) do
          {:ok, value} ->
            :persistent_term.put(memo_key, {stamps, value})
            value

          _miss ->
            value = compute.()
            if trusted? and keep?(value), do: keep(memo_key, stamps, store, kept, value)
            value
        end
    end
  end

  @doc "Drops every value this VM keeps (`memo/4`); a store's stay."
  @spec forget() :: :ok
  def forget do
    for {{__MODULE__, _} = key, _value} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end

  @doc """
  A file's stamp: `{size, mtime, inode, ctime}` (POSIX seconds), or
  `:absent`.
  """
  @spec stamp(Path.t()) :: {non_neg_integer(), integer(), integer(), integer()} | :absent
  def stamp(path) do
    case :file.read_file_info(path, [:raw, {:time, :posix}]) do
      {:ok, info} ->
        {file_info(info, :size), file_info(info, :mtime), file_info(info, :inode),
         file_info(info, :ctime)}

      {:error, _} ->
        :absent
    end
  end

  defp trusted?(:absent, _cutoff), do: true
  defp trusted?({_size, mtime, _inode, _ctime}, cutoff), do: mtime < cutoff

  defp keep?(:error), do: false
  defp keep?({:error, _}), do: false
  defp keep?(_value), do: true

  defp keep(memo_key, stamps, store, kept, value) do
    :persistent_term.put(memo_key, {stamps, value})
    if store != nil, do: _ = Blob.remember(store, kept, value)
    :ok
  end
end
