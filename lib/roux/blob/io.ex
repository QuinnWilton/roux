defmodule Roux.Blob.IO do
  @moduledoc false
  # The store's file operations, every one raw: straight to the operating
  # system from the calling process, never through the VM's file server
  # (`file_server_2`), which serializes every `File` call of the whole VM.
  # A fan-out of lookups (`Roux.Runtime.parallel/3`) runs side by side
  # only if its file operations do.
  #
  # Errors come back as `File` returns them: `{:error, posix}`, a vanished
  # file `{:error, :enoent}`.
  #
  # ## The hook
  #
  # A test that holds a race open needs to act between two of the store's
  # steps. The file-server stand-in that used to do it cannot see raw
  # calls, so every operation here calls a hook after it completes and
  # before its caller sees the result: `install_hook/1` sets one for the
  # whole VM (tests run it in a VM of their own), `remove_hook/0` takes it
  # away. Without one, the cost is a `:persistent_term` read.

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @hook {__MODULE__, :hook}

  @typedoc "What a hook is called with: the operation's name and the path it named."
  @type hook :: (atom(), Path.t() -> any())

  @spec install_hook(hook()) :: :ok
  def install_hook(hook) when is_function(hook, 2), do: :persistent_term.put(@hook, hook)

  @spec remove_hook() :: :ok
  def remove_hook do
    _ = :persistent_term.erase(@hook)
    :ok
  end

  defp after_op(result, op, path) do
    case :persistent_term.get(@hook, nil) do
      nil -> :ok
      hook -> hook.(op, path)
    end

    result
  end

  @spec read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path), do: path |> :file.read_file([:raw]) |> after_op(:read_file, path)

  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write(path, data), do: path |> :file.write_file(data, [:raw]) |> after_op(:write_file, path)

  @spec stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def stat(path) do
    path
    |> :file.read_file_info([:raw, {:time, :posix}])
    |> to_stat()
    |> after_op(:read_file_info, path)
  end

  @spec lstat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def lstat(path) do
    path
    |> :file.read_link_info([:raw, {:time, :posix}])
    |> to_stat()
    |> after_op(:read_link_info, path)
  end

  defp to_stat({:ok, info}), do: {:ok, File.Stat.from_record(info)}
  defp to_stat({:error, _} = error), do: error

  @doc """
  The names in `dir`, or `[]` when it cannot be listed (not there).
  """
  @spec ls(Path.t()) :: [String.t()]
  def ls(dir) do
    result =
      case :prim_file.list_dir(dir) do
        {:ok, names} -> Enum.map(names, &IO.chardata_to_string/1)
        {:error, _} -> []
      end

    after_op(result, :list_dir, dir)
  end

  @spec rename(Path.t(), Path.t()) :: :ok | {:error, File.posix()}
  def rename(from, to), do: from |> :prim_file.rename(to) |> after_op(:rename, from)

  @spec delete(Path.t()) :: :ok | {:error, File.posix()}
  def delete(path), do: path |> :prim_file.delete() |> after_op(:delete, path)

  @spec link(Path.t(), Path.t()) :: :ok | {:error, File.posix()}
  def link(existing, new),
    do: existing |> :prim_file.make_link(new) |> after_op(:make_link, existing)

  @spec chmod(Path.t(), non_neg_integer()) :: :ok | {:error, File.posix()}
  def chmod(path, mode) do
    path
    |> :file.write_file_info(file_info(mode: mode), [:raw])
    |> after_op(:write_file_info, path)
  end

  @doc """
  Sets `path`'s access and modification times to `time` (POSIX seconds):
  fails on a path that is not there, and never makes one.
  """
  @spec utime(Path.t(), integer()) :: :ok | {:error, File.posix()}
  def utime(path, time) do
    path
    |> :file.write_file_info(file_info(mtime: time, atime: time), [:raw, {:time, :posix}])
    |> after_op(:write_file_info, path)
  end

  @doc "Makes `dir`: `{:error, :eexist}` when something is there already."
  @spec mkdir(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir(dir), do: dir |> :prim_file.make_dir() |> after_op(:make_dir, dir)

  @doc "Makes `dir`, and its parents when they are missing."
  @spec mkdir_p(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir_p(dir) do
    result =
      case :prim_file.make_dir(dir) do
        :ok ->
          :ok

        {:error, :eexist} ->
          :ok

        {:error, :enoent} ->
          parent = Path.dirname(dir)

          with true <- parent != dir,
               :ok <- mkdir_p(parent) do
            case :prim_file.make_dir(dir) do
              :ok -> :ok
              {:error, :eexist} -> :ok
              error -> error
            end
          else
            false -> {:error, :enoent}
            error -> error
          end

        {:error, _} = error ->
          error
      end

    after_op(result, :make_dir, dir)
  end
end
