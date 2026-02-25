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
end
