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
  #
  # ## A model file system
  #
  # A process that set a backend (`put_backend/1`) has every operation
  # answered by that module instead — the same functions, the same
  # returns — and no hook called: the Concuerror scenarios run the store's
  # own code over a model file system (`Roux.Test.ModelFS`) whose every
  # step is a scheduling point. Without one, the cost is a process
  # dictionary read.

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @hook {__MODULE__, :hook}
  @backend {__MODULE__, :backend}

  @typedoc "What a hook is called with: the operation's name and the path it named."
  @type hook :: (atom(), Path.t() -> any())

  @spec install_hook(hook()) :: :ok
  def install_hook(hook) when is_function(hook, 2), do: :persistent_term.put(@hook, hook)

  @spec remove_hook() :: :ok
  def remove_hook do
    _ = :persistent_term.erase(@hook)
    :ok
  end

  @doc "Answers the calling process's operations with `module` (nil: the real file system)."
  @spec put_backend(module() | nil) :: :ok
  def put_backend(nil) do
    Process.delete(@backend)
    :ok
  end

  def put_backend(module) when is_atom(module) do
    Process.put(@backend, module)
    :ok
  end

  # `op` of the backend the calling process set, or `raw` then the hook.
  defp dispatch(op, args, path, raw) do
    case Process.get(@backend) do
      nil ->
        result = raw.()

        case :persistent_term.get(@hook, nil) do
          nil -> :ok
          hook -> hook.(op, path)
        end

        result

      module ->
        apply(module, op, args)
    end
  end

  @spec read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path), do: dispatch(:read_file, [path], path, fn -> :file.read_file(path, [:raw]) end)

  @spec read_slice(Path.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | :eof | {:error, File.posix()}
  def read_slice(path, offset, length) do
    dispatch(:read_slice, [path, offset, length], path, fn ->
      case :file.open(path, [:read, :raw, :binary]) do
        {:ok, file} ->
          try do
            :file.pread(file, offset, length)
          after
            :file.close(file)
          end

        error ->
          error
      end
    end)
  end

  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write(path, data),
    do: dispatch(:write_file, [path, data], path, fn -> :file.write_file(path, data, [:raw]) end)

  @spec stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def stat(path) do
    dispatch(:read_file_info, [path], path, fn ->
      path |> :file.read_file_info([:raw, {:time, :posix}]) |> to_stat()
    end)
  end

  @spec lstat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def lstat(path) do
    dispatch(:read_link_info, [path], path, fn ->
      path |> :file.read_link_info([:raw, {:time, :posix}]) |> to_stat()
    end)
  end

  defp to_stat({:ok, info}), do: {:ok, File.Stat.from_record(info)}
  defp to_stat({:error, _} = error), do: error

  @doc "The names in `dir`, or `[]` when it cannot be listed (not there)."
  @spec ls(Path.t()) :: [String.t()]
  def ls(dir) do
    dispatch(:list_dir, [dir], dir, fn ->
      case :prim_file.list_dir(dir) do
        {:ok, names} -> Enum.map(names, &IO.chardata_to_string/1)
        {:error, _} -> []
      end
    end)
  end

  @doc """
  Renames `from` to `to`, replacing a `to` that is there. Replacing is
  not atomic everywhere: on APFS a concurrent `link/2` or open of `to`
  can find no name while it happens. Never rename over a name readers
  count on being there (a CAS entry): `link/2` an entry into place.
  """
  @spec rename(Path.t(), Path.t()) :: :ok | {:error, File.posix()}
  def rename(from, to),
    do: dispatch(:rename, [from, to], from, fn -> :prim_file.rename(from, to) end)

  @spec delete(Path.t()) :: :ok | {:error, File.posix()}
  def delete(path), do: dispatch(:delete, [path], path, fn -> :prim_file.delete(path) end)

  @doc "Makes `new` a hard link to `existing`: `{:error, :eexist}` when `new` is there."
  @spec link(Path.t(), Path.t()) :: :ok | {:error, File.posix()}
  def link(existing, new),
    do:
      dispatch(:make_link, [existing, new], existing, fn ->
        :prim_file.make_link(existing, new)
      end)

  @spec chmod(Path.t(), non_neg_integer()) :: :ok | {:error, File.posix()}
  def chmod(path, mode) do
    dispatch(:chmod, [path, mode], path, fn ->
      :file.write_file_info(path, file_info(mode: mode), [:raw])
    end)
  end

  @doc """
  Sets `path`'s access and modification times to `time` (POSIX seconds):
  fails on a path that is not there, and never makes one.
  """
  @spec utime(Path.t(), integer()) :: :ok | {:error, File.posix()}
  def utime(path, time) do
    dispatch(:utime, [path, time], path, fn ->
      :file.write_file_info(path, file_info(mtime: time, atime: time), [:raw, {:time, :posix}])
    end)
  end

  @doc "Makes `dir`: `{:error, :eexist}` when something is there already."
  @spec mkdir(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir(dir), do: dispatch(:make_dir, [dir], dir, fn -> :prim_file.make_dir(dir) end)

  @doc "Removes the empty directory `dir`."
  @spec rmdir(Path.t()) :: :ok | {:error, File.posix()}
  def rmdir(dir), do: dispatch(:del_dir, [dir], dir, fn -> :prim_file.del_dir(dir) end)

  @doc "Makes `dir`, and its parents when they are missing."
  @spec mkdir_p(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir_p(dir) do
    case mkdir(dir) do
      :ok ->
        :ok

      {:error, :eexist} ->
        :ok

      {:error, :enoent} ->
        parent = Path.dirname(dir)

        with true <- parent != dir,
             :ok <- mkdir_p(parent) do
          case mkdir(dir) do
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
  end

  @doc """
  Removes `path` and everything under it; a path not there is no error.
  Symbolic links are removed, never followed.
  """
  @spec rm_rf(Path.t()) :: :ok
  def rm_rf(path) do
    case lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        path |> ls() |> Enum.each(&rm_rf(Path.join(path, &1)))
        _ = rmdir(path)
        :ok

      {:ok, _file_or_link} ->
        _ = delete(path)
        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc "The SHA-256 of a file's bytes, lowercase hex, read in chunks."
  @spec hash_file(Path.t()) :: {:ok, String.t()} | {:error, File.posix()}
  def hash_file(path) do
    dispatch(:hash_file, [path], path, fn ->
      case :file.open(path, [:read, :raw, :binary, {:read_ahead, 1_048_576}]) do
        {:ok, device} ->
          try do
            {:ok,
             device |> hash_device(:crypto.hash_init(:sha256)) |> Base.encode16(case: :lower)}
          after
            :file.close(device)
          end

        {:error, _} = error ->
          error
      end
    end)
  end

  defp hash_device(device, hash) do
    case :file.read(device, 1_048_576) do
      {:ok, data} -> hash_device(device, :crypto.hash_update(hash, data))
      :eof -> :crypto.hash_final(hash)
    end
  end

  @doc """
  What names this OS process's own files in the store (staging files,
  scratch directories): its OS pid and a random token drawn once per VM,
  so a VM that is given a dead process's pid (pids are reused) names
  nothing that process left behind. The model's own process name under
  a backend.
  """
  @spec ospid() :: String.t()
  def ospid do
    case Process.get(@backend) do
      nil -> "#{:os.getpid()}.#{vm_token()}"
      module -> module.ospid()
    end
  end

  defp vm_token do
    key = {__MODULE__, :vm_token}

    case :persistent_term.get(key, nil) do
      nil ->
        token = random_token()
        :persistent_term.put(key, token)
        token

      token ->
        token
    end
  end

  defp random_token,
    do: 0x100000000 |> :rand.uniform() |> Integer.to_string(16) |> String.downcase()

  @doc "A positive integer no earlier call in this VM (or model process) returned."
  @spec unique() :: pos_integer()
  def unique do
    case Process.get(@backend) do
      nil -> System.unique_integer([:positive])
      module -> module.unique()
    end
  end
end
