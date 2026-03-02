defmodule Roux.ValidationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Roux.{Database, Memo, Revision, Validation}
  alias Roux.Memo.Entry

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

  # -- Helpers --

  defp make_entry(overrides) do
    value = Keyword.get(overrides, :value, :some_value)

    %Entry{
      value: value,
      hash: Keyword.get(overrides, :hash, :erlang.phash2(value)),
      changed_at: Keyword.get(overrides, :changed_at, 1),
      verified_at: Keyword.get(overrides, :verified_at, 1),
      dependencies: Keyword.get(overrides, :dependencies, []),
      durability: Keyword.get(overrides, :durability, :low),
      output_entities: Keyword.get(overrides, :output_entities, [])
    }
  end

  defp noop_ensure(_db, _dep), do: :ok

  defp recursive_ensure(db, dep_key) do
    Validation.validate(db, dep_key, &recursive_ensure/2)
    :ok
  end

  # Simulates what Runtime.ensure_up_to_date would do: validate, and if stale,
  # re-execute (updating changed_at and verified_at to current revision).
  defp reexecuting_ensure(db, dep_key) do
    case Validation.validate(db, dep_key, &reexecuting_ensure/2) do
      :valid ->
        :ok

      :stale ->
        current = Revision.current(db.revision)
        {:ok, old} = Memo.get(db, dep_key)
        Memo.put(db, dep_key, %{old | changed_at: current, verified_at: current})
        :ok
    end
  end

  defp tracking_ensure(agent) do
    fn _db, dep_key ->
      Agent.update(agent, &(&1 ++ [dep_key]))
      :ok
    end
  end

  # -- Case 1: no memo --

  describe "case 1: no memo" do
    test "returns :stale when no memo entry exists", %{db: db} do
      assert Validation.validate(db, {:parse, "file.ex"}, &noop_ensure/2) == :stale
    end
  end

  # -- Case 2: already validated --

  describe "case 2: already validated this revision" do
    test "returns :valid and does not call ensure_fn", %{db: db} do
      Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      entry = make_entry(verified_at: current_rev)
      Memo.put(db, {:parse, "file.ex"}, entry)

      {:ok, agent} = Agent.start_link(fn -> [] end)

      assert Validation.validate(db, {:parse, "file.ex"}, tracking_ensure(agent)) == :valid
      assert Agent.get(agent, & &1) == []

      Agent.stop(agent)
    end

    test "returns :valid at revision 0 when entry verified_at is 0", %{db: db} do
      # Initial revision is 0, entry verified at 0.
      entry = make_entry(verified_at: 0)
      Memo.put(db, {:parse, "file.ex"}, entry)

      assert Validation.validate(db, {:parse, "file.ex"}, &noop_ensure/2) == :valid
    end
  end

  # -- Case 3: durability skip --

  describe "case 3: durability skip" do
    test "returns :valid when no inputs at that durability level changed", %{db: db} do
      # Advance via :low only — :high slot stays at 0.
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      # Entry with :high durability, verified at rev 1.
      # last_changed_at_or_below(:high) == 0 <= 1, so durability skip fires.
      entry = make_entry(verified_at: 1, durability: :high)
      Memo.put(db, {:parse, "file.ex"}, entry)

      assert Validation.validate(db, {:parse, "file.ex"}, &noop_ensure/2) == :valid

      # verified_at should be updated to current revision.
      {:ok, updated} = Memo.get(db, {:parse, "file.ex"})
      assert updated.verified_at == current_rev
    end

    test "medium durability skips when only low inputs changed", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      entry = make_entry(verified_at: 1, durability: :medium)
      Memo.put(db, {:compile, "file.ex"}, entry)

      assert Validation.validate(db, {:compile, "file.ex"}, &noop_ensure/2) == :valid

      {:ok, updated} = Memo.get(db, {:compile, "file.ex"})
      assert updated.verified_at == current_rev
    end

    test "does not fire when same-level inputs changed", %{db: db} do
      # Advance via :high — :high slot becomes 1.
      Revision.advance(db.revision, :high)

      # Dependency that has changed.
      dep_key = {:input, :config, :target}
      Memo.put(db, dep_key, make_entry(changed_at: 1, verified_at: 1))

      # Entry verified at 0, durability :high.
      # last_changed_at_or_below(:high) == 1 > 0, durability skip doesn't fire.
      entry = make_entry(verified_at: 0, durability: :high, dependencies: [dep_key])
      Memo.put(db, {:parse, "file.ex"}, entry)

      # Falls through to case 4: dep changed_at 1 > verified_at 0 → stale.
      assert Validation.validate(db, {:parse, "file.ex"}, &noop_ensure/2) == :stale
    end
  end

  # -- Case 4: walk dependencies --

  describe "case 4: walk dependencies" do
    test "returns :stale when dependency changed_at exceeds verified_at", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)

      dep_key = {:input, :source, "dep.ex"}
      Memo.put(db, dep_key, make_entry(changed_at: 2, verified_at: 2))

      entry = make_entry(verified_at: 1, dependencies: [dep_key])
      Memo.put(db, {:parse, "file.ex"}, entry)

      assert Validation.validate(db, {:parse, "file.ex"}, &noop_ensure/2) == :stale
    end

    test "returns :valid when all dependencies unchanged", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      dep_key = {:input, :source, "dep.ex"}
      Memo.put(db, dep_key, make_entry(changed_at: 1, verified_at: 2))

      entry = make_entry(verified_at: 1, dependencies: [dep_key])
      Memo.put(db, {:parse, "file.ex"}, entry)

      assert Validation.validate(db, {:parse, "file.ex"}, &noop_ensure/2) == :valid

      {:ok, updated} = Memo.get(db, {:parse, "file.ex"})
      assert updated.verified_at == current_rev
    end

    test "early cutoff: dep re-executed but changed_at stayed old → valid", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)

      dep_key = {:input, :source, "dep.ex"}
      # Dep was re-executed at rev 2 but produced the same value,
      # so changed_at stayed at 1. Only verified_at advanced.
      Memo.put(db, dep_key, make_entry(changed_at: 1, verified_at: 2))

      entry = make_entry(verified_at: 1, dependencies: [dep_key])
      Memo.put(db, {:parse, "file.ex"}, entry)

      # changed_at 1 is NOT > verified_at 1, so dep is clean.
      assert Validation.validate(db, {:parse, "file.ex"}, &noop_ensure/2) == :valid
    end

    test "no dependencies → valid", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      entry = make_entry(verified_at: 1, dependencies: [])
      Memo.put(db, {:parse, "file.ex"}, entry)

      assert Validation.validate(db, {:parse, "file.ex"}, &noop_ensure/2) == :valid

      {:ok, updated} = Memo.get(db, {:parse, "file.ex"})
      assert updated.verified_at == current_rev
    end
  end

  # -- Transitive validation --

  describe "transitive validation" do
    test "A→B→C, ensure_fn triggers B's validation transitively", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)

      c_key = {:input, :source, "c.ex"}
      Memo.put(db, c_key, make_entry(changed_at: 1, verified_at: 2))

      b_key = {:compile, "b.ex"}
      Memo.put(db, b_key, make_entry(changed_at: 1, verified_at: 1, dependencies: [c_key]))

      a_key = {:compile, "a.ex"}
      Memo.put(db, a_key, make_entry(changed_at: 1, verified_at: 1, dependencies: [b_key]))

      # C unchanged (changed_at 1 == B.verified_at 1). B valid.
      # B unchanged (changed_at 1 == A.verified_at 1). A valid.
      assert Validation.validate(db, a_key, &recursive_ensure/2) == :valid
    end

    test "A→B→C, C changed propagates staleness to A", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)

      c_key = {:input, :source, "c.ex"}
      # C changed at rev 2.
      Memo.put(db, c_key, make_entry(changed_at: 2, verified_at: 2))

      b_key = {:compile, "b.ex"}
      # B was verified at rev 1 — hasn't seen C's change yet.
      Memo.put(db, b_key, make_entry(changed_at: 1, verified_at: 1, dependencies: [c_key]))

      a_key = {:compile, "a.ex"}
      Memo.put(db, a_key, make_entry(changed_at: 1, verified_at: 1, dependencies: [b_key]))

      # reexecuting_ensure validates B recursively. B sees C changed (2 > 1),
      # so B is stale and gets re-executed (changed_at updated to current_rev).
      # A then sees B.changed_at (2) > A.verified_at (1) → A is stale.
      assert Validation.validate(db, a_key, &reexecuting_ensure/2) == :stale
    end
  end

  # -- ensure_fn tracking --

  describe "ensure_fn behavior" do
    test "called for each dependency in order", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)

      dep1 = {:input, :source, "a.ex"}
      dep2 = {:input, :source, "b.ex"}
      dep3 = {:input, :source, "c.ex"}

      for dep <- [dep1, dep2, dep3] do
        Memo.put(db, dep, make_entry(changed_at: 1, verified_at: 2))
      end

      entry = make_entry(verified_at: 1, dependencies: [dep1, dep2, dep3])
      Memo.put(db, {:compile, "all.ex"}, entry)

      {:ok, agent} = Agent.start_link(fn -> [] end)

      Validation.validate(db, {:compile, "all.ex"}, tracking_ensure(agent))

      assert Agent.get(agent, & &1) == [dep1, dep2, dep3]
      Agent.stop(agent)
    end

    test "short-circuits on first stale dep", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)

      stale_dep = {:input, :source, "stale.ex"}
      Memo.put(db, stale_dep, make_entry(changed_at: 2, verified_at: 2))

      fresh_dep = {:input, :source, "fresh.ex"}
      Memo.put(db, fresh_dep, make_entry(changed_at: 1, verified_at: 2))

      entry = make_entry(verified_at: 1, dependencies: [stale_dep, fresh_dep])
      Memo.put(db, {:compile, "query.ex"}, entry)

      {:ok, agent} = Agent.start_link(fn -> [] end)

      assert Validation.validate(db, {:compile, "query.ex"}, tracking_ensure(agent)) == :stale

      # Only the first (stale) dep's ensure_fn was called.
      assert Agent.get(agent, & &1) == [stale_dep]
      Agent.stop(agent)
    end
  end

  # -- verified_at update --

  describe "verified_at update" do
    test "updated to current revision after successful case 4 validation", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      query_key = {:compile, "file.ex"}
      entry = make_entry(verified_at: 1, dependencies: [])
      Memo.put(db, query_key, entry)

      assert Validation.validate(db, query_key, &noop_ensure/2) == :valid

      {:ok, updated} = Memo.get(db, query_key)
      assert updated.verified_at == current_rev
    end

    test "not updated on :stale result", %{db: db} do
      Revision.advance(db.revision, :low)
      Revision.advance(db.revision, :low)

      dep_key = {:input, :source, "dep.ex"}
      Memo.put(db, dep_key, make_entry(changed_at: 2, verified_at: 2))

      query_key = {:compile, "file.ex"}
      entry = make_entry(verified_at: 1, dependencies: [dep_key])
      Memo.put(db, query_key, entry)

      assert Validation.validate(db, query_key, &noop_ensure/2) == :stale

      {:ok, unchanged} = Memo.get(db, query_key)
      assert unchanged.verified_at == 1
    end
  end

  # -- Input query keys --

  describe "input query keys" do
    test "validates input query keys correctly", %{db: db} do
      Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      query_key = {:input, :source, "file.ex"}
      entry = make_entry(verified_at: current_rev)
      Memo.put(db, query_key, entry)

      assert Validation.validate(db, query_key, &noop_ensure/2) == :valid
    end
  end

  # -- Property tests --

  describe "properties" do
    property "staleness correctness: validation result matches brute-force dep check" do
      check all(
              num_deps <- integer(0..5),
              query_verified_at <- integer(1..10),
              gap <- integer(1..5),
              dep_changed_ats <- list_of(integer(1..15), length: num_deps)
            ) do
        db = Database.new()

        # Ensure current_rev is large enough to exceed all generated values.
        current_rev = query_verified_at + gap

        for _ <- 1..current_rev, do: Revision.advance(db.revision, :low)

        deps =
          dep_changed_ats
          |> Enum.with_index()
          |> Enum.map(fn {changed_at, i} ->
            dep_key = {:dep, i}
            Memo.put(db, dep_key, make_entry(changed_at: changed_at, verified_at: current_rev))
            dep_key
          end)

        entry = make_entry(verified_at: query_verified_at, dependencies: deps, durability: :low)
        Memo.put(db, {:query, :test}, entry)

        result = Validation.validate(db, {:query, :test}, &noop_ensure/2)

        # Brute-force: stale iff any dep's changed_at > query's verified_at.
        # Case 2 never fires because gap >= 1 ensures current_rev > query_verified_at.
        # Durability skip never fires: all revisions advanced via :low, so
        # last_changed_at_or_below(:low) == current_rev > query_verified_at.
        expected =
          if Enum.any?(dep_changed_ats, &(&1 > query_verified_at)),
            do: :stale,
            else: :valid

        assert result == expected

        Database.shutdown(db)
      end
    end

    property "durability precondition: skip fires only when no relevant-level inputs changed" do
      check all(
              num_deps <- integer(0..5),
              query_verified_at <- integer(1..10),
              gap <- integer(1..5),
              dep_changed_ats <- list_of(integer(1..10), length: num_deps)
            ) do
        db = Database.new()

        current_rev = query_verified_at + gap

        # Advance all via :low — :high slot stays at 0.
        for _ <- 1..current_rev, do: Revision.advance(db.revision, :low)

        deps =
          dep_changed_ats
          |> Enum.with_index()
          |> Enum.map(fn {changed_at, i} ->
            dep_key = {:dep, i}

            Memo.put(
              db,
              dep_key,
              make_entry(changed_at: changed_at, verified_at: current_rev)
            )

            dep_key
          end)

        # Use :high durability. Since all revisions advanced via :low,
        # last_changed_at_or_below(:high) == 0, which is <= any verified_at >= 1.
        # The durability skip should fire and return :valid.
        entry =
          make_entry(verified_at: query_verified_at, dependencies: deps, durability: :high)

        Memo.put(db, {:query, :test}, entry)

        assert Validation.validate(db, {:query, :test}, &noop_ensure/2) == :valid

        # Verify the precondition that justifies the skip:
        # no input at the :high durability level has changed since verified_at.
        assert Revision.last_changed_at_or_below(db.revision, :high) <= query_verified_at

        Database.shutdown(db)
      end
    end
  end

  # -- Stress tests --

  describe "stress tests" do
    test "deep dependency chain (150 levels)", %{db: db} do
      depth = 150

      for _ <- 1..2, do: Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      # Build a linear chain: q_0 → q_1 → q_2 → ... → q_{depth-1} → leaf input.
      leaf = {:input, :source, "leaf.ex"}
      Memo.put(db, leaf, make_entry(changed_at: 1, verified_at: current_rev))

      # Build from the bottom up so each node depends on the one below it.
      keys =
        Enum.reduce((depth - 1)..0//-1, [leaf], fn i, [child | _] = acc ->
          key = {:deep, i}
          Memo.put(db, key, make_entry(verified_at: 1, dependencies: [child]))
          [key | acc]
        end)

      root = hd(keys)

      assert Validation.validate(db, root, &recursive_ensure/2) == :valid

      {:ok, updated} = Memo.get(db, root)
      assert updated.verified_at == current_rev
    end

    test "deep dependency chain detects staleness at bottom", %{db: db} do
      depth = 150

      for _ <- 1..2, do: Revision.advance(db.revision, :low)

      # Leaf changed at rev 2, all nodes verified at rev 1.
      leaf = {:input, :source, "leaf.ex"}
      Memo.put(db, leaf, make_entry(changed_at: 2, verified_at: 2))

      keys =
        Enum.reduce((depth - 1)..0//-1, [leaf], fn i, [child | _] = acc ->
          key = {:deep, i}
          Memo.put(db, key, make_entry(verified_at: 1, dependencies: [child]))
          [key | acc]
        end)

      root = hd(keys)

      # Staleness at the leaf propagates through the entire chain.
      assert Validation.validate(db, root, &reexecuting_ensure/2) == :stale
    end

    test "wide dependency fan (200 deps)", %{db: db} do
      width = 200

      for _ <- 1..2, do: Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      # All deps unchanged.
      deps =
        for i <- 0..(width - 1) do
          dep_key = {:input, :source, "file_#{i}.ex"}
          Memo.put(db, dep_key, make_entry(changed_at: 1, verified_at: current_rev))
          dep_key
        end

      query_key = {:compile, "all.ex"}
      entry = make_entry(verified_at: 1, dependencies: deps)
      Memo.put(db, query_key, entry)

      assert Validation.validate(db, query_key, &noop_ensure/2) == :valid
    end

    test "wide dependency fan detects single stale dep", %{db: db} do
      width = 200

      for _ <- 1..2, do: Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      # All deps unchanged except the last one.
      deps =
        for i <- 0..(width - 1) do
          dep_key = {:input, :source, "file_#{i}.ex"}
          changed_at = if i == width - 1, do: 2, else: 1
          Memo.put(db, dep_key, make_entry(changed_at: changed_at, verified_at: current_rev))
          dep_key
        end

      query_key = {:compile, "all.ex"}
      entry = make_entry(verified_at: 1, dependencies: deps)
      Memo.put(db, query_key, entry)

      assert Validation.validate(db, query_key, &noop_ensure/2) == :stale
    end

    test "diamond pattern: A → {B, C} → D", %{db: db} do
      for _ <- 1..2, do: Revision.advance(db.revision, :low)
      current_rev = Revision.current(db.revision)

      # D is the shared leaf, unchanged.
      d_key = {:input, :source, "d.ex"}
      Memo.put(db, d_key, make_entry(changed_at: 1, verified_at: current_rev))

      # B and C both depend on D.
      b_key = {:compile, "b.ex"}
      Memo.put(db, b_key, make_entry(changed_at: 1, verified_at: 1, dependencies: [d_key]))

      c_key = {:compile, "c.ex"}
      Memo.put(db, c_key, make_entry(changed_at: 1, verified_at: 1, dependencies: [d_key]))

      # A depends on both B and C.
      a_key = {:compile, "a.ex"}
      Memo.put(db, a_key, make_entry(changed_at: 1, verified_at: 1, dependencies: [b_key, c_key]))

      assert Validation.validate(db, a_key, &recursive_ensure/2) == :valid

      {:ok, updated} = Memo.get(db, a_key)
      assert updated.verified_at == current_rev
    end

    test "diamond pattern detects staleness through shared dep", %{db: db} do
      for _ <- 1..2, do: Revision.advance(db.revision, :low)

      # D changed at rev 2.
      d_key = {:input, :source, "d.ex"}
      Memo.put(db, d_key, make_entry(changed_at: 2, verified_at: 2))

      b_key = {:compile, "b.ex"}
      Memo.put(db, b_key, make_entry(changed_at: 1, verified_at: 1, dependencies: [d_key]))

      c_key = {:compile, "c.ex"}
      Memo.put(db, c_key, make_entry(changed_at: 1, verified_at: 1, dependencies: [d_key]))

      a_key = {:compile, "a.ex"}
      Memo.put(db, a_key, make_entry(changed_at: 1, verified_at: 1, dependencies: [b_key, c_key]))

      assert Validation.validate(db, a_key, &reexecuting_ensure/2) == :stale
    end
  end
end
