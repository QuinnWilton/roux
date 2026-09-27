defmodule Roux.Test.ModelFS do
  @moduledoc """
  A file system in an ETS table, for the Concuerror scenarios of the
  blob store (`test/concurrency/blob_test.ex`): `Roux.Blob.IO` answers a
  process's operations from it once the process `enter/2`s it, so the
  store's own code runs over a file system whose every step is a
  scheduling point Concuerror can interleave.

  A name is a row, `{{:name, path}, kind, inode}` (`kind` `:file` or
  `:dir`); an inode is `{{:inode, inode}, content, mtime, mode}`, its
  bytes written once. A hard link is another name for the inode: it
  shares bytes, time and mode, and survives the removal of the name it
  was made from.

  stat(2), utime(2) and chmod(2) resolve a name and read or change its
  inode in one system call. Here they resolve the name, read or change
  the inode, and look again: a name no longer on that inode reports
  ENOENT, as a call made after the name went would (a change, on the
  inode, can only keep an entry a collection would otherwise take —
  never lose one). A read resolves the name once, as an open does: the
  bytes of a file removed after that are still read.

  Every operation is one step on a name, as a system call is — except
  the one that is not atomic on APFS: a rename that REPLACES an existing
  name removes the name, then installs the new inode under it, so a
  concurrent link(2) or open between the two finds no name. A rename
  onto a free name is one step (a lookup may briefly see both names,
  which nothing here minds).

  Each actor names the model OS process it belongs to (`enter/2`'s
  `ospid`), which is what `Roux.Blob.IO.ospid/0` returns to it; its
  `Roux.Blob.IO.unique/0` counts from 1 per model OS process, as a new
  VM's unique integers restart.
  """

  @table {__MODULE__, :table}
  @ospid {__MODULE__, :ospid}

  @doc "A fresh file system holding the root directory."
  def new do
    table = :ets.new(__MODULE__, [:set, :public])
    :ets.insert(table, {{:inode, :root}, nil, 0, 0o700})
    :ets.insert(table, {{:name, "/"}, :dir, :root})
    table
  end

  @doc "Makes the calling process one of model OS process `ospid`'s, on `table`."
  def enter(table, ospid) do
    Process.put(@table, table)
    Process.put(@ospid, ospid)
    Roux.Blob.IO.put_backend(__MODULE__)
  end

  def ospid, do: Process.get(@ospid)

  # (Concuerror has no `update_counter/4`: the counter is made first.)
  def unique do
    key = {:counter, ospid()}
    _ = :ets.insert_new(t(), {key, 0})
    :ets.update_counter(t(), key, 1)
  end

  defp t, do: Process.get(@table)

  defp lookup(path) do
    case :ets.lookup(t(), {:name, path}) do
      [{_, kind, ino}] -> {kind, ino}
      [] -> nil
    end
  end

  defp dir?(path), do: match?({:dir, _}, lookup(path))

  defp inode(ino) do
    [{_, content, mtime, mode}] = :ets.lookup(t(), {:inode, ino})
    {content, mtime, mode}
  end

  defp new_inode(content, mode) do
    ino = :erlang.unique_integer([:positive])
    :ets.insert(t(), {{:inode, ino}, content, System.os_time(:second), mode})
    ino
  end

  def read_file(path) do
    case lookup(path) do
      {:file, ino} -> {:ok, elem(inode(ino), 0)}
      {:dir, _} -> {:error, :eisdir}
      nil -> {:error, :enoent}
    end
  end

  def write_file(path, data) do
    if dir?(Path.dirname(path)) do
      ino = new_inode(IO.iodata_to_binary(data), 0o644)
      :ets.insert(t(), {{:name, path}, :file, ino})
      :ok
    else
      {:error, :enoent}
    end
  end

  def read_file_info(path), do: info(path)
  def read_link_info(path), do: info(path)

  defp info(path) do
    case stable(path) do
      {:file, ino, {content, mtime, mode}} ->
        {:ok,
         %File.Stat{
           type: :regular,
           size: byte_size(content),
           mtime: mtime,
           atime: mtime,
           ctime: mtime,
           mode: Bitwise.bor(0o100000, mode),
           uid: 501,
           inode: ino,
           links: 1
         }}

      {:dir, _ino, {_, mtime, mode}} ->
        {:ok,
         %File.Stat{
           type: :directory,
           size: 0,
           mtime: mtime,
           mode: Bitwise.bor(0o40000, mode),
           uid: 501
         }}

      nil ->
        {:error, :enoent}
    end
  end

  # The name's entry and its inode as read, only if the name still holds
  # that inode after the read (`info/1`).
  defp stable(path) do
    with {kind, ino} <- lookup(path) do
      read = inode(ino)
      if lookup(path) == {kind, ino}, do: {kind, ino, read}
    end
  end

  def list_dir(dir) do
    for [path] <- :ets.match(t(), {{:name, :"$1"}, :_, :_}),
        path != dir and Path.dirname(path) == dir,
        do: Path.basename(path)
  end

  def rename(from, to) do
    case :ets.lookup(t(), {:name, from}) do
      [] ->
        {:error, :enoent}

      [{_, kind, ino}] ->
        row = {{:name, to}, kind, ino}

        case lookup(to) do
          nil ->
            :ets.insert(t(), row)
            :ets.delete(t(), {:name, from})
            :ok

          _replaced ->
            # APFS: the old name goes, then the new inode comes.
            :ets.delete(t(), {:name, to})
            :ets.insert(t(), row)
            :ets.delete(t(), {:name, from})
            :ok
        end
    end
  end

  def make_link(existing, new) do
    case :ets.lookup(t(), {:name, existing}) do
      [{_, :file, ino}] ->
        cond do
          not dir?(Path.dirname(new)) -> {:error, :enoent}
          :ets.insert_new(t(), {{:name, new}, :file, ino}) -> :ok
          true -> {:error, :eexist}
        end

      [{_, :dir, _}] ->
        {:error, :eperm}

      [] ->
        {:error, :enoent}
    end
  end

  def delete(path) do
    case lookup(path) do
      {:file, _} ->
        :ets.delete(t(), {:name, path})
        :ok

      {:dir, _} ->
        {:error, :eperm}

      nil ->
        {:error, :enoent}
    end
  end

  def chmod(path, mode), do: update(path, 4, mode)
  def utime(path, time), do: update(path, 3, time)

  # Resolve, change the inode, look again (see the moduledoc).
  defp update(path, position, value) do
    case lookup(path) do
      {_kind, ino} ->
        :ets.update_element(t(), {:inode, ino}, {position, value})
        if match?({_, ^ino}, lookup(path)), do: :ok, else: {:error, :enoent}

      nil ->
        {:error, :enoent}
    end
  end

  def make_dir(dir) do
    cond do
      not dir?(Path.dirname(dir)) ->
        {:error, :enoent}

      :ets.insert_new(t(), {{:name, dir}, :dir, new_inode(nil, 0o700)}) ->
        :ok

      true ->
        {:error, :eexist}
    end
  end

  def del_dir(dir) do
    cond do
      not dir?(dir) ->
        {:error, :enoent}

      list_dir(dir) != [] ->
        {:error, :eexist}

      true ->
        :ets.delete(t(), {:name, dir})
        :ok
    end
  end

  def hash_file(path) do
    with {:ok, content} <- read_file(path) do
      {:ok, :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)}
    end
  end
end
