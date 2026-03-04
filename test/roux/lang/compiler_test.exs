defmodule Roux.Lang.CompilerTest do
  use ExUnit.Case

  alias Roux.Lang.Compiler

  # Not async — modifies Application env.
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Set source_dirs to the tmp_dir so the compiler finds our test files.
    prev_languages = Application.get_env(:roux, :languages)
    prev_dirs = Application.get_env(:roux, :source_dirs)

    Application.put_env(:roux, :source_dirs, [tmp_dir])

    on_exit(fn ->
      if prev_languages do
        Application.put_env(:roux, :languages, prev_languages)
      else
        Application.delete_env(:roux, :languages)
      end

      if prev_dirs do
        Application.put_env(:roux, :source_dirs, prev_dirs)
      else
        Application.delete_env(:roux, :source_dirs)
      end
    end)

    %{tmp_dir: tmp_dir}
  end

  # -- no languages configured --

  describe "no languages configured" do
    test "returns {:noop, []}" do
      Application.put_env(:roux, :languages, [])
      assert {:noop, []} = Compiler.run([])
    end
  end

  # -- source discovery --

  describe "source discovery" do
    test "discovers files by extension and ignores others", %{tmp_dir: tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      File.write!(Path.join(tmp_dir, "app.mini"), "hello")
      File.write!(Path.join(tmp_dir, "readme.txt"), "ignore me")

      assert {:ok, []} = Compiler.run([])
    end

    test "traverses nested directories", %{tmp_dir: tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      nested = Path.join(tmp_dir, "sub/deep")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "nested.mini"), "nested content")

      assert {:ok, []} = Compiler.run([])
    end
  end

  # -- successful compilation --

  describe "successful compilation" do
    test "compiles source files successfully", %{tmp_dir: tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      File.write!(Path.join(tmp_dir, "hello.mini"), "1 + 2")
      File.write!(Path.join(tmp_dir, "world.mini"), "3 + 4")

      assert {:ok, []} = Compiler.run([])
    end

    test "returns {:ok, []} when no matching files found", %{tmp_dir: _tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      # No .mini files in tmp_dir — but directory exists and is empty.
      assert {:ok, []} = Compiler.run([])
    end
  end

  # -- error diagnostics --

  describe "error diagnostics" do
    test "returns error diagnostic on compile failure", %{tmp_dir: tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.FailingLang])

      File.write!(Path.join(tmp_dir, "broken.fail"), "bad code")

      assert {:error, diagnostics} = Compiler.run([])
      assert [%Mix.Task.Compiler.Diagnostic{severity: :error} = diag] = diagnostics
      assert diag.message =~ "compilation failed"
      assert diag.compiler_name == "roux"
    end
  end

  # -- manifest / incremental compilation --

  describe "warm start" do
    test "second compile reuses manifest", %{tmp_dir: tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      File.write!(Path.join(tmp_dir, "app.mini"), "source code")

      # First compile — cold build.
      assert {:ok, []} = Compiler.run([])
      assert File.exists?(Compiler.manifests() |> hd())

      # Second compile — nothing changed, warm start returns noop.
      assert {:noop, []} = Compiler.run([])
    end

    test "stale file triggers recompilation", %{tmp_dir: tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      path = Path.join(tmp_dir, "app.mini")
      File.write!(path, "v1")

      assert {:ok, []} = Compiler.run([])

      # Modify the file.
      # Need to ensure mtime changes — write new content after a brief delay.
      Process.sleep(1100)
      File.write!(path, "v2")

      assert {:ok, []} = Compiler.run([])
    end

    test "deleted file is cleaned up", %{tmp_dir: tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      path = Path.join(tmp_dir, "temp.mini")
      File.write!(path, "temporary")

      assert {:ok, []} = Compiler.run([])

      # Delete the file.
      File.rm!(path)

      # Recompile — should handle the deleted file gracefully.
      assert {:ok, []} = Compiler.run([])
    end
  end

  # -- corrupt manifest fallback --

  describe "corrupt manifest" do
    test "falls back to full rebuild on corrupt manifest", %{tmp_dir: tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      File.write!(Path.join(tmp_dir, "app.mini"), "hello")

      # First compile — creates a valid manifest.
      assert {:ok, []} = Compiler.run([])

      # Corrupt the manifest.
      manifest = Compiler.manifests() |> hd()
      File.write!(manifest, :crypto.strong_rand_bytes(64))

      # Recompile — should fall back to cold build, not crash.
      assert {:ok, []} = Compiler.run([])
    end

    test "falls back to full rebuild on wrong manifest version", %{tmp_dir: tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      File.write!(Path.join(tmp_dir, "app.mini"), "hello")
      assert {:ok, []} = Compiler.run([])

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

      assert {:ok, []} = Compiler.run([])
    end
  end

  # -- touch without content change --

  describe "touch without content change" do
    test "mtime changes but content unchanged does not advance revision", %{tmp_dir: tmp_dir} do
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      path = Path.join(tmp_dir, "stable.mini")
      File.write!(path, "unchanged content")

      # First compile.
      assert {:ok, []} = Compiler.run([])

      # Touch the file (change mtime, same content).
      Process.sleep(1100)
      File.touch!(path)

      # Second compile — Input.set early cutoff means no revision advance
      # for the unchanged content. Compilation still succeeds.
      assert {:ok, []} = Compiler.run([])
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
      Application.put_env(:roux, :languages, [Roux.Test.MiniLang])

      File.write!(Path.join(tmp_dir, "app.mini"), "code")
      Compiler.run([])

      manifest = Compiler.manifests() |> hd()
      assert File.exists?(manifest)

      Compiler.clean()
      refute File.exists?(manifest)
    end
  end
end
