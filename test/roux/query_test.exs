defmodule Roux.QueryTest do
  use ExUnit.Case, async: true

  alias Roux.Database
  alias Roux.Query.Definition
  alias Roux.Test.EmptyQueries
  alias Roux.Test.SampleQueries

  # Ensure fixture modules are loaded before function_exported? checks.
  Code.ensure_loaded!(Roux.Test.SampleQueries)
  Code.ensure_loaded!(Roux.Test.EmptyQueries)

  # -- Definition.new --

  describe "Definition.new/3" do
    test "creates struct with correct fields" do
      defn = Definition.new(:parse, MyModule, :parse)

      assert %Definition{
               name: :parse,
               module: MyModule,
               function: :parse,
               opts: []
             } = defn
    end

    test "default opts is []" do
      defn = Definition.new(:parse, MyModule, :parse)
      assert defn.opts == []
    end
  end

  describe "Definition.new/4" do
    test "with explicit opts" do
      defn = Definition.new(:parse, MyModule, :parse, timeout: 5000)
      assert defn.opts == [timeout: 5000]
    end
  end

  # -- defquery --

  describe "defquery" do
    test "generated function exists with arity 2" do
      assert function_exported?(Roux.Test.SampleQueries, :parse, 2)
      assert function_exported?(Roux.Test.SampleQueries, :typecheck, 2)
    end

    test "__query_definition__/1 returns correct Definition for each query" do
      parse_defn = SampleQueries.__query_definition__(:parse)

      assert %Definition{
               name: :parse,
               module: Roux.Test.SampleQueries,
               function: :parse,
               opts: []
             } = parse_defn

      typecheck_defn = SampleQueries.__query_definition__(:typecheck)

      assert %Definition{
               name: :typecheck,
               module: Roux.Test.SampleQueries,
               function: :typecheck,
               opts: []
             } = typecheck_defn
    end

    test "multiple queries in one module all registered" do
      %{queries: queries} = SampleQueries.__roux_queries__()
      names = Enum.map(queries, & &1.name)
      assert :parse in names
      assert :typecheck in names
    end

    test "destructured key pattern works" do
      assert function_exported?(Roux.Test.SampleQueries, :typecheck, 2)
      defn = SampleQueries.__query_definition__(:typecheck)
      assert defn.name == :typecheck
    end
  end

  # -- definput --

  describe "definput" do
    test "input definitions accumulated in __roux_queries__/0" do
      %{inputs: inputs} = SampleQueries.__roux_queries__()
      names = Enum.map(inputs, & &1.name)
      assert :source_text in names
      assert :config in names
      assert :events in names
    end

    test "default durability is :medium" do
      %{inputs: inputs} = SampleQueries.__roux_queries__()
      events = Enum.find(inputs, &(&1.name == :events))
      assert events.durability == :medium
    end

    test "explicit durability preserved" do
      %{inputs: inputs} = SampleQueries.__roux_queries__()
      source_text = Enum.find(inputs, &(&1.name == :source_text))
      config = Enum.find(inputs, &(&1.name == :config))
      assert source_text.durability == :low
      assert config.durability == :high
    end
  end

  # -- __roux_queries__/0 --

  describe "__roux_queries__/0" do
    test "returns %{queries: [...], inputs: [...]}" do
      result = SampleQueries.__roux_queries__()
      assert %{queries: queries, inputs: inputs} = result
      assert is_list(queries)
      assert is_list(inputs)
    end

    test "queries and inputs in definition order" do
      %{queries: queries, inputs: inputs} = SampleQueries.__roux_queries__()
      query_names = Enum.map(queries, & &1.name)
      input_names = Enum.map(inputs, & &1.name)
      assert query_names == [:parse, :typecheck]
      assert input_names == [:source_text, :config, :events]
    end

    test "empty module returns %{queries: [], inputs: [], entities: []}" do
      assert %{queries: [], inputs: [], entities: []} =
               EmptyQueries.__roux_queries__()
    end
  end

  # -- defentity --

  describe "defentity" do
    test "entity modules accumulated in __roux_queries__/0" do
      %{entities: entities} = SampleQueries.__roux_queries__()
      assert Roux.Test.SampleEntity in entities
    end

    test "empty module has no entities" do
      %{entities: entities} = EmptyQueries.__roux_queries__()
      assert entities == []
    end
  end

  # -- Registration --

  describe "registration" do
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

    test "Database.register_query/3 accepts Definition data", %{db: db} do
      defn = Definition.new(:parse, Roux.Test.SampleQueries, :parse)
      assert :ok = Database.register_query(db, defn.name, Map.from_struct(defn))
    end

    test "register_module/2 auto-registers declared entities", %{db: db} do
      Roux.Lang.register_module(db, Roux.Test.SampleQueries)

      # Entity should be registered — creating an instance should work.
      entity_id =
        Roux.Entity.create(db, Roux.Test.SampleEntity, %{name: :x, body: :y, return_type: :z}, 1)

      assert is_integer(entity_id)
    end

    test "duplicate registration is idempotent", %{db: db} do
      defn = Definition.new(:parse, Roux.Test.SampleQueries, :parse)
      Database.register_query(db, defn.name, Map.from_struct(defn))

      # Re-registering does not raise.
      assert :ok = Database.register_query(db, defn.name, Map.from_struct(defn))
    end
  end

  # -- Macro hygiene --

  describe "macro hygiene" do
    test "db variable is in scope inside defquery body" do
      # SampleQueries.parse returns {db, file_path} — if db weren't in scope,
      # compilation would have failed.
      assert function_exported?(Roux.Test.SampleQueries, :parse, 2)
    end

    test "key variable is in scope inside defquery body" do
      # SampleQueries.typecheck uses destructured key {file_path, opts} — both
      # variables are accessible in the body. Compilation success proves this.
      assert function_exported?(Roux.Test.SampleQueries, :typecheck, 2)
    end
  end
end
