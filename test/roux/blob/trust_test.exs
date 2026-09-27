defmodule Roux.Blob.TrustTest do
  @moduledoc """
  A store is trusted as the manifest is — its terms decode with their
  atoms — and `Roux.Blob.open/1` enforces what that trust rests on: a
  root and `FORMAT` owned by this user and writable by no one else.
  """

  use ExUnit.Case, async: true

  alias Roux.Blob
  alias Roux.Blob.{Trace, TrustError}

  @moduletag :tmp_dir

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  describe "decoding in a fresh VM" do
    # A VM of this one's code that has never seen the atoms a test makes.
    defp peer! do
      {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})
      :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])

      on_exit(fn ->
        try do
          :peer.stop(peer)
        catch
          :exit, _ -> :ok
        end
      end)

      peer
    end

    test "terms naming atoms the VM never made are hits, in every kind of entry",
         %{tmp_dir: tmp} do
      store = Blob.open!(Path.join(tmp, "store"))
      unseen = fn -> "roux_trust_unseen_#{System.unique_integer([:positive])}" end
      [cas, ac, trace] = names = for _ <- 1..3, do: unseen.()
      value = fn name -> %{finding: {String.to_atom(name), :handle_call, 3}} end
      n = System.unique_integer([:positive])

      # Keys a caller in any VM knows; values naming atoms only this VM
      # has made so far.
      {:ok, digest} = Blob.put_term(store, value.(cas))
      :ok = Blob.remember(store, {:key, n}, value.(ac))
      # Observed by `Function.identity/1`: a function the peer has on disk.
      :ok = Trace.put(store, {:trace, n}, [{1, 1}], value.(trace))

      peer = peer!()

      # The peer has made none of them: `:safe` would miss all three.
      for name <- names do
        assert catch_error(
                 :peer.call(peer, :erlang, :list_to_existing_atom, [String.to_charlist(name)])
               )
      end

      assert :peer.call(peer, Blob, :get_term, [store, digest]) == {:ok, value.(cas)}
      assert :peer.call(peer, Blob, :recall, [store, {:key, n}]) == {:ok, value.(ac)}

      assert :peer.call(peer, Trace, :find, [store, {:trace, n}, &Function.identity/1]) ==
               {:ok, value.(trace)}
    end
  end

  describe "open/1" do
    test "makes a new root 0700 and its FORMAT writable by no one", %{tmp_dir: tmp} do
      store = Blob.open!(Path.join(tmp, "new/store"))
      assert mode(store.root) == 0o700
      assert Bitwise.band(mode(Path.join(store.root, "FORMAT")), 0o222) == 0

      temporary = Blob.temporary()
      assert mode(temporary.root) == 0o700
      Blob.destroy(temporary)
    end

    test "refuses a root its group or everyone can write", %{tmp_dir: tmp} do
      for bits <- [0o770, 0o757] do
        root = Path.join(tmp, "shared-#{Integer.to_string(bits, 8)}")
        File.mkdir_p!(root)
        File.chmod!(root, bits)

        assert {:error, %TrustError{reason: :writable_by_others, path: ^root}} = Blob.open(root)
        error = assert_raise TrustError, fn -> Blob.open!(root) end
        assert Exception.message(error) =~ root
        assert Exception.message(error) =~ "chmod go-w"
        refute File.exists?(Path.join(root, "FORMAT"))
      end
    end

    test "refuses an existing store whose FORMAT has been made writable", %{tmp_dir: tmp} do
      store = Blob.open!(Path.join(tmp, "store"))
      format = Path.join(store.root, "FORMAT")
      File.chmod!(format, 0o666)

      assert {:error, %TrustError{reason: :writable_by_others, path: ^format}} =
               Blob.open(store.root)
    end

    test "refuses a FORMAT that is a symbolic link", %{tmp_dir: tmp} do
      store = Blob.open!(Path.join(tmp, "store"))
      format = Path.join(store.root, "FORMAT")
      elsewhere = Path.join(tmp, "format-elsewhere")
      File.cp!(format, elsewhere)
      File.rm!(format)
      File.ln_s!(elsewhere, format)

      assert {:error, %TrustError{reason: :not_a_regular_file}} = Blob.open(store.root)
    end

    test "refuses a root another user owns" do
      # A system directory: root's, unless the suite itself runs as root.
      root = "/usr"
      assert File.stat!(root).uid == 0

      if File.stat!(System.tmp_dir!()).uid != 0 and own_uid() != 0 do
        assert {:error, %TrustError{reason: :not_owner, owner: 0, path: ^root}} = Blob.open(root)
        assert Exception.message(assert_raise(TrustError, fn -> Blob.open!(root) end)) =~ "chown"
      end
    end

    test "follows a symbolic root to a target it trusts, and refuses one it does not",
         %{tmp_dir: tmp} do
      target = Blob.open!(Path.join(tmp, "target")).root
      link = Path.join(tmp, "link")
      File.ln_s!(target, link)
      assert {:ok, %Blob{root: ^link}} = Blob.open(link)

      shared = Path.join(tmp, "shared")
      File.mkdir_p!(shared)
      File.chmod!(shared, 0o777)
      shared_link = Path.join(tmp, "shared-link")
      File.ln_s!(shared, shared_link)
      assert {:error, %TrustError{reason: :writable_by_others}} = Blob.open(shared_link)
    end

    test "refuses a root that is not a directory", %{tmp_dir: tmp} do
      file = Path.join(tmp, "a-file")
      File.write!(file, "")
      assert {:error, %TrustError{reason: :not_a_directory}} = Blob.open(file)
    end
  end

  defp own_uid do
    probe = Path.join(System.tmp_dir!(), "roux-trust-#{System.unique_integer([:positive])}")
    File.write!(probe, "")

    try do
      File.stat!(probe).uid
    after
      File.rm(probe)
    end
  end
end
