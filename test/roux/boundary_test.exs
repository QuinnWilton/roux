defmodule Roux.BoundaryTest do
  use ExUnit.Case
  use AssertBoundary, app: :roux

  # Boundary enforcement per D16. Each subsystem declares its allowed Roux
  # dependencies as an allowlist. Any call to a module outside the allowlist
  # fails the test. Add new subsystems here as they are implemented.

  describe "Tier 0: Foundation" do
    test "Roux.Intern has no Roux dependencies", %{boundary: boundary} do
      assert_boundary(boundary, modules: under(Roux.Intern), allow: [])
    end

    test "Roux.Revision has no Roux dependencies", %{boundary: boundary} do
      assert_boundary(boundary, modules: under(Roux.Revision), allow: [])
    end

    test "Roux.Telemetry has no Roux dependencies", %{boundary: boundary} do
      assert_boundary(boundary, modules: under(Roux.Telemetry), allow: [])
    end
  end

  describe "Tier 1: Database" do
    test "Roux.Database depends only on Intern, Revision, and Telemetry", %{boundary: boundary} do
      assert_boundary(boundary,
        modules: under(Roux.Database),
        allow: [under(Roux.Intern), under(Roux.Revision), under(Roux.Telemetry)]
      )
    end
  end

  describe "Tier 1: Memo" do
    test "Roux.Memo depends only on Database", %{boundary: boundary} do
      assert_boundary(boundary,
        modules: under(Roux.Memo),
        allow: [under(Roux.Database)]
      )
    end
  end

  describe "Tier 2: Input" do
    test "Roux.Input depends only on Database, Revision, Memo, and Telemetry", %{
      boundary: boundary
    } do
      assert_boundary(boundary,
        modules: under(Roux.Input),
        allow: [
          under(Roux.Database),
          under(Roux.Revision),
          under(Roux.Memo),
          under(Roux.Telemetry)
        ]
      )
    end
  end

  describe "Tier 2: Query" do
    test "Roux.Query depends only on Database", %{boundary: boundary} do
      assert_boundary(boundary,
        modules: under(Roux.Query),
        allow: [under(Roux.Database)]
      )
    end
  end

  describe "Tier 2: Entity" do
    test "Roux.Entity depends only on Database and Intern", %{boundary: boundary} do
      assert_boundary(boundary,
        modules: under(Roux.Entity),
        allow: [under(Roux.Database), under(Roux.Intern)]
      )
    end
  end

  describe "Tier 2: Cycle" do
    test "Roux.Cycle depends only on Runtime.Context", %{boundary: boundary} do
      assert_boundary(boundary,
        modules: under(Roux.Cycle),
        allow: [under(Roux.Runtime.Context)]
      )
    end
  end

  describe "Tier 2: Validation" do
    test "Roux.Validation depends only on Database, Memo, Revision, and Telemetry", %{
      boundary: boundary
    } do
      assert_boundary(boundary,
        modules: under(Roux.Validation),
        allow: [
          under(Roux.Database),
          under(Roux.Memo),
          under(Roux.Revision),
          under(Roux.Telemetry)
        ]
      )
    end
  end

  describe "Tier 3: Runtime" do
    test "Roux.Runtime depends only on Database, Memo, Input, Validation, Telemetry, and Cycle",
         %{
           boundary: boundary
         } do
      assert_boundary(boundary,
        modules: [Roux.Runtime],
        allow: [
          under(Roux.Database),
          under(Roux.Memo),
          under(Roux.Input),
          under(Roux.Validation),
          under(Roux.Telemetry),
          under(Roux.Cycle),
          under(Roux.Runtime.Context),
          under(Roux.Revision),
          under(Roux.Cancellation),
          under(Roux.GC)
        ]
      )
    end
  end

  describe "Tier 3: Cancellation" do
    test "Roux.Cancellation depends only on Database, Memo, and Telemetry", %{
      boundary: boundary
    } do
      assert_boundary(boundary,
        modules: under(Roux.Cancellation),
        allow: [
          under(Roux.Database),
          under(Roux.Memo),
          under(Roux.Telemetry)
        ]
      )
    end
  end

  describe "Tier 3: GC" do
    test "Roux.GC depends only on Database, Memo, Entity, Revision, and Telemetry", %{
      boundary: boundary
    } do
      assert_boundary(boundary,
        modules: under(Roux.GC),
        allow: [
          under(Roux.Database),
          under(Roux.Memo),
          under(Roux.Entity),
          under(Roux.Revision),
          under(Roux.Telemetry)
        ]
      )
    end
  end
end
