defmodule Roux.LangTest do
  use ExUnit.Case, async: true

  alias Roux.{Database, Input, Lang, Runtime}
  alias Roux.Test.MiniLang

  setup do
    db = Database.new()

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    %{db: db}
  end

  # -- register/2 --

  describe "register/2" do
    test "registers a language and maps its extensions", %{db: db} do
      assert :ok = Lang.register(db, Roux.Test.MiniLang)
      assert {:ok, Roux.Test.MiniLang} = Lang.lang_for_extension(db, ".mini")
    end

    test "idempotent re-registration succeeds", %{db: db} do
      assert :ok = Lang.register(db, Roux.Test.MiniLang)
      assert :ok = Lang.register(db, Roux.Test.MiniLang)
      assert {:ok, Roux.Test.MiniLang} = Lang.lang_for_extension(db, ".mini")
    end

    test "raises on extension conflict", %{db: db} do
      Lang.register(db, Roux.Test.MiniLang)

      # Inline module that also claims ".mini".
      defmodule ConflictLang do
        @behaviour Roux.Lang

        @impl true
        def file_extensions, do: [".mini"]

        @impl true
        def compile_query, do: :conflict_compile

        @impl true
        def register_queries(_db), do: :ok
      end

      assert_raise ArgumentError, ~r/already claimed by/, fn ->
        Lang.register(db, ConflictLang)
      end
    end
  end

  # -- register_module/2 --

  describe "register_module/2" do
    test "registers queries and inputs from a module", %{db: db} do
      Lang.register_module(db, Roux.Test.MiniLang)

      # Inputs are registered — setting a value should not raise.
      Input.set(db, :source_text, "test.mini", "hello")
      assert Input.get(db, :source_text, "test.mini") == "hello"

      # Queries are registered — the query registry has entries.
      assert [{:mini_parse, _}] = :ets.lookup(db.query_registry, :mini_parse)
      assert [{:mini_compile, _}] = :ets.lookup(db.query_registry, :mini_compile)
    end
  end

  # -- lang_for_extension/2 --

  describe "lang_for_extension/2" do
    test "returns :error for unregistered extension", %{db: db} do
      assert :error = Lang.lang_for_extension(db, ".unknown")
    end

    test "returns {:ok, module} for registered extension", %{db: db} do
      Lang.register(db, Roux.Test.MiniLang)
      assert {:ok, Roux.Test.MiniLang} = Lang.lang_for_extension(db, ".mini")
    end
  end

  # -- registered_languages/1 --

  describe "registered_languages/1" do
    test "returns empty list when no languages registered", %{db: db} do
      assert Lang.registered_languages(db) == []
    end

    test "lists registered languages", %{db: db} do
      Lang.register(db, Roux.Test.MiniLang)
      assert Roux.Test.MiniLang in Lang.registered_languages(db)
    end
  end

  # -- resolve_interface/2 --

  describe "resolve_interface/2" do
    test "raises on unknown extension", %{db: db} do
      assert_raise ArgumentError, ~r/no language registered for extension/, fn ->
        Lang.resolve_interface(db, "foo.unknown")
      end
    end

    test "dispatches to language's module_interface callback", %{db: db} do
      defmodule InterfaceLang do
        @behaviour Roux.Lang
        use Roux.Query

        @impl Roux.Lang
        def file_extensions, do: [".iface"]

        @impl Roux.Lang
        def compile_query, do: :iface_compile

        @impl Roux.Lang
        def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

        @impl Roux.Lang
        def module_interface(_db, source_path) do
          {:interface, source_path}
        end

        defquery :iface_compile, key: path do
          _ = {db, path}
          :compiled
        end
      end

      Lang.register(db, InterfaceLang)
      assert {:interface, "test.iface"} = Lang.resolve_interface(db, "test.iface")
    end
  end

  # -- Behaviour callbacks --

  describe "behaviour callbacks" do
    test "compile_query returns the correct name" do
      assert MiniLang.compile_query() == :mini_compile
    end

    test "file_extensions returns the correct list" do
      assert MiniLang.file_extensions() == [".mini"]
    end
  end

  # -- End-to-end --

  describe "end-to-end lifecycle" do
    test "register, set input, execute query", %{db: db} do
      Lang.register(db, Roux.Test.MiniLang)

      Input.set(db, :source_text, "hello.mini", "1 + 2")

      result =
        Runtime.execute(db, :mini_compile, "hello.mini", fn db, path ->
          ast =
            Runtime.execute(db, :mini_parse, path, fn db, p ->
              Input.get(db, :source_text, p)
            end)

          {:compiled, ast}
        end)

      assert result == {:compiled, "1 + 2"}
    end
  end

  # -- Integration --

  describe "two languages in the same database" do
    test "compiling files of different extensions", %{db: db} do
      Lang.register(db, Roux.Test.MiniLang)
      Lang.register(db, Roux.Test.TinyLang)

      # Both languages coexist — extensions resolve independently.
      assert {:ok, Roux.Test.MiniLang} = Lang.lang_for_extension(db, ".mini")
      assert {:ok, Roux.Test.TinyLang} = Lang.lang_for_extension(db, ".tiny")

      langs = Lang.registered_languages(db)
      assert Roux.Test.MiniLang in langs
      assert Roux.Test.TinyLang in langs

      # Set inputs for both languages.
      Input.set(db, :source_text, "app.mini", "mini source")
      Input.set(db, :tiny_source, "app.tiny", "tiny source")

      # Execute each language's compile query through the runtime.
      mini_result = MiniLang.mini_compile(db, "app.mini")
      assert mini_result == {:compiled, "mini source"}

      tiny_result = Roux.Test.TinyLang.tiny_compile(db, "app.tiny")
      assert tiny_result == %{exports: [:main], compiled: "tiny source"}
    end
  end

  describe "cross-language dependency" do
    test "language A imports module interface from language B", %{db: db} do
      # TinyLang exposes a module_interface callback.
      # We define an inline language that depends on TinyLang's interface.
      defmodule ImporterLang do
        @behaviour Roux.Lang
        use Roux.Query

        @impl Roux.Lang
        def file_extensions, do: [".imp"]

        @impl Roux.Lang
        def compile_query, do: :imp_compile

        @impl Roux.Lang
        def register_queries(db), do: Roux.Lang.register_module(db, __MODULE__)

        definput :imp_source, durability: :low

        defquery :imp_compile, key: path do
          source = Roux.Runtime.input(db, :imp_source, path)

          # Parse the source to find an import directive, then resolve it.
          case source do
            {:import, dep_path, body} ->
              dep_interface = Roux.Lang.resolve_interface(db, dep_path)
              {:compiled, body, imports: dep_interface}

            body ->
              {:compiled, body, imports: nil}
          end
        end
      end

      Lang.register(db, Roux.Test.TinyLang)
      Lang.register(db, ImporterLang)

      # TinyLang file that ImporterLang will depend on.
      Input.set(db, :tiny_source, "lib.tiny", "tiny exports")

      # ImporterLang file that imports from the TinyLang file.
      Input.set(db, :imp_source, "app.imp", {:import, "lib.tiny", "importer body"})

      result = ImporterLang.imp_compile(db, "app.imp")

      # ImporterLang resolved TinyLang's module interface via resolve_interface.
      assert {:compiled, "importer body", imports: %{exports: [:main], compiled: "tiny exports"}} =
               result
    end
  end
end
