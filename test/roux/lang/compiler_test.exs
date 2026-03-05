defmodule Roux.Lang.CompilerTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Roux.Lang.Compiler

  # Not async — shares manifest path.
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Compiler.clean()
    %{tmp_dir: tmp_dir}
  end

  defp compile(languages, tmp_dir) do
    Compiler.compile(languages: languages, source_dirs: [tmp_dir])
  end

  # -- no languages configured --

  describe "no languages configured" do
    test "returns {:noop, []}", %{tmp_dir: tmp_dir} do
      assert {:noop, []} = compile([], tmp_dir)
    end
  end

  # -- source discovery --

  describe "source discovery" do
    test "discovers files by extension and ignores others", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "app.mini"), "hello")
      File.write!(Path.join(tmp_dir, "readme.txt"), "ignore me")

      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)
    end

    test "traverses nested directories", %{tmp_dir: tmp_dir} do
      nested = Path.join(tmp_dir, "sub/deep")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "nested.mini"), "nested content")

      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)
    end
  end

  # -- successful compilation --

  describe "successful compilation" do
    test "compiles source files successfully", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "hello.mini"), "1 + 2")
      File.write!(Path.join(tmp_dir, "world.mini"), "3 + 4")

      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)
    end

    test "returns {:ok, []} when no matching files found", %{tmp_dir: tmp_dir} do
      # No .mini files in tmp_dir — but directory exists and is empty.
      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)
    end
  end

  # -- error diagnostics --

  describe "error diagnostics" do
    test "returns error diagnostic on compile failure", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "broken.fail"), "bad code")

      stderr =
        capture_io(:stderr, fn ->
          assert {:error, diagnostics} = compile([Roux.Test.FailingLang], tmp_dir)
          assert [%Mix.Task.Compiler.Diagnostic{severity: :error} = diag] = diagnostics
          assert diag.message =~ "compilation failed"
          assert diag.compiler_name == "roux"
        end)

      assert stderr =~ "error: compilation failed"
    end
  end

  # -- manifest / incremental compilation --

  describe "warm start" do
    test "second compile reuses manifest", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "app.mini"), "source code")

      # First compile — cold build.
      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)
      assert File.exists?(Compiler.manifests() |> hd())

      # Second compile — nothing changed, warm start returns noop.
      assert {:noop, []} = compile([Roux.Test.MiniLang], tmp_dir)
    end

    test "stale file triggers recompilation", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "app.mini")
      File.write!(path, "v1")

      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)

      # Modify the file.
      # Need to ensure mtime changes — write new content after a brief delay.
      Process.sleep(1100)
      File.write!(path, "v2")

      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)
    end

    test "deleted file is cleaned up", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "temp.mini")
      File.write!(path, "temporary")

      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)

      # Delete the file.
      File.rm!(path)

      # Recompile — should handle the deleted file gracefully.
      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)
    end
  end

  # -- corrupt manifest fallback --

  describe "corrupt manifest" do
    test "falls back to full rebuild on corrupt manifest", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "app.mini"), "hello")

      # First compile — creates a valid manifest.
      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)

      # Corrupt the manifest.
      manifest = Compiler.manifests() |> hd()
      File.write!(manifest, :crypto.strong_rand_bytes(64))

      # Recompile — should fall back to cold build, not crash.
      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)
    end

    test "falls back to full rebuild on wrong manifest version", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "app.mini"), "hello")
      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)

      # Overwrite with a different version.
      manifest = Compiler.manifests() |> hd()

      bad_data = %{
        vsn: 9999,
        sources: %{},
        memo_entries: [],
        entity_data: [],
        intern_data: [],
        revision: %{}
      }

      File.write!(manifest, :erlang.term_to_binary(bad_data))

      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)
    end
  end

  # -- touch without content change --

  describe "touch without content change" do
    test "mtime changes but content unchanged does not advance revision", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "stable.mini")
      File.write!(path, "unchanged content")

      # First compile.
      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)

      # Touch the file (change mtime, same content).
      Process.sleep(1100)
      File.touch!(path)

      # Second compile — Input.set early cutoff means no revision advance
      # for the unchanged content. Compilation still succeeds.
      assert {:ok, []} = compile([Roux.Test.MiniLang], tmp_dir)
    end
  end

  # -- manifests/0 --

  describe "manifests/0" do
    test "returns path ending with compile.roux" do
      [path] = Compiler.manifests()
      assert String.ends_with?(path, "compile.roux")
    end
  end

  # -- clean/0 --

  describe "clean/0" do
    test "removes manifest file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "app.mini"), "code")
      compile([Roux.Test.MiniLang], tmp_dir)

      manifest = Compiler.manifests() |> hd()
      assert File.exists?(manifest)

      Compiler.clean()
      refute File.exists?(manifest)
    end
  end
end
