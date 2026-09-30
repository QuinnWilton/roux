defmodule Roux.DependenciesRaceTest do
  # The paused blob-read test installs the process-wide Blob.IO hook.
  use ExUnit.Case, async: false

  alias Roux.{
    Blob,
    Database,
    Dependencies,
    Input,
    Memo,
    QueryLog,
    Revision,
    Runtime,
    Session,
    Validation
  }

  alias Roux.Lang.Manifest
  alias Roux.Test.PersistQueries

  setup do
    db = Database.new(reverse_dependencies: true)
    Input.register(db, Input.define(:source))

    on_exit(fn ->
      try do
        Database.shutdown(db)
      catch
        :exit, _ -> :ok
      end
    end)

    %{db: db}
  end

  test "an old validation cannot stamp a replacement memo", %{db: db} do
    Input.set(db, :source, :a, 1)
    leaf = fn db, key -> rem(Runtime.input(db, :source, key), 2) end
    parent = fn db, key -> Runtime.execute(db, :leaf, key, leaf) end
    assert Runtime.execute(db, :parent, :a, parent) == 1
    {:ok, before} = Memo.get(db, {:parent, :a})
    Input.set(db, :source, :a, 3)

    ensure = fn db, {:leaf, :a} ->
      assert Runtime.execute(db, :leaf, :a, leaf) == 1
      # A computation that overlapped the edit can finish while this older
      # validation is walking dependencies. Its result is deliberately not
      # certified; the validation belongs to the incarnation it started on.
      Memo.publish(db, {:parent, :a}, before, false, nil)
    end

    assert Validation.validate(db, {:parent, :a}, ensure) == :valid

    assert Memo.verification_state(db, {:parent, :a}) ==
             {:ok, before.verified_at, before.durability}
  end

  @tag :tmp_dir
  test "a blob read cannot cache an older value under a replacement generation", %{
    db: db,
    tmp_dir: dir
  } do
    {:ok, store} = Blob.open(Path.join(dir, "store"))
    db = %{db | blob: store}
    key = {:saved, :a}
    assert Runtime.execute(db, :saved, :a, fn _, _ -> 1 end) == 1
    rows = Memo.persisted(db, fn _, _ -> true end)
    [row] = rows
    {:ok, digest} = Blob.put_term(store, 1)
    Memo.restore_persisted(db, [put_elem(row, 7, {:blob, digest})])
    test_pid = self()

    Blob.IO.install_hook(fn operation, _path ->
      if operation == :read_file and Process.get(:pause_saved_blob) do
        Process.delete(:pause_saved_blob)
        send(test_pid, {:blob_read, self()})

        receive do
          :resume_blob -> :ok
        end
      end
    end)

    on_exit(fn -> Blob.IO.remove_hook() end)

    reader =
      Task.async(fn ->
        Process.put(:pause_saved_blob, true)
        first = Runtime.execute(db, :saved, :a, fn _, _ -> 1 end)
        second = Runtime.execute(db, :saved, :a, fn _, _ -> 2 end)
        {first, second}
      end)

    assert_receive {:blob_read, reader_pid}
    {:ok, old} = Memo.get(db, key)
    Memo.put(db, key, %{old | value: 2, hash: :erlang.phash2(2)})
    assert Runtime.execute(db, :saved, :a, fn _, _ -> 2 end) == 2
    assert Dependencies.status(db, key) == :clean
    send(reader_pid, :resume_blob)
    assert {_concurrent_result, 2} = Task.await(reader)
  end

  test "query keys containing match specification atoms keep separate certificates", %{db: db} do
    for key <- [:"$1", :_, {"nested", :"$2"}] do
      Input.set(db, :source, key, 1)

      assert Runtime.execute(db, :read, key, fn db, key -> Runtime.input(db, :source, key) end) ==
               1
    end

    Input.set(db, :source, :"$1", 2)

    assert Runtime.execute(db, :read, :"$1", fn db, key -> Runtime.input(db, :source, key) end) ==
             2

    assert Dependencies.status(db, {:read, :_}) == :clean
    assert Dependencies.status(db, {:read, {"nested", :"$2"}}) == :clean
    assert Revision.current(db.revision) > 0
  end

  test "first code-version registration invalidates existing closure memos", %{db: db} do
    leaf = fn _, _ -> 1 end
    parent = fn db, key -> Runtime.execute(db, :versioned_leaf, key, leaf) end
    assert Runtime.execute(db, :versioned_parent, :a, parent) == 1
    Database.register_query(db, :versioned_leaf, %{code_version: "registered"})
    leaf = fn _, _ -> 2 end
    parent = fn db, key -> Runtime.execute(db, :versioned_leaf, key, leaf) end
    assert Runtime.execute(db, :versioned_parent, :a, parent) == 2
  end

  test "reverse edges and certificates survive table-owner restart", %{db: db} do
    Input.set(db, :source, :a, 1)
    leaf = fn db, key -> Runtime.input(db, :source, key) end
    parent = fn db, key -> Runtime.execute(db, :restart_leaf, key, leaf) end
    assert Runtime.execute(db, :restart_parent, :a, parent) == 1
    owner = owner(db)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    wait_for_owner(db, owner, 100)
    assert Dependencies.status(db, {:restart_parent, :a}) == :clean
    Input.set(db, :source, :a, 2)
    assert Dependencies.status(db, {:restart_parent, :a}) == :check
    assert Runtime.execute(db, :restart_parent, :a, parent) == 2
  end

  @tag :tmp_dir
  test "a restored missing value blob reloads without losing early cutoff", %{tmp_dir: dir} do
    opts = [
      modules: [PersistQueries],
      blob: Path.join(dir, "blobs"),
      manifest: Path.join(dir, "manifest"),
      reverse_dependencies: true
    ]

    first = Session.open(opts)
    Input.set(first.db, :psrc, :a, 1)
    assert PersistQueries.p_blob(first.db, :a) == 1
    Session.commit(first, %{})
    Session.close(first)
    second = Session.open(opts)

    try do
      assert second.restored?
      assert {:ok, digest} = Memo.held_digest(second.db, {:p_blob, :a})
      {:ok, changed_at} = Memo.changed_at(second.db, {:p_blob, :a})
      File.rm!(Blob.path(second.blob, digest))
      log = QueryLog.start(second.db)
      assert PersistQueries.p_blob(second.db, :a) == 1
      assert QueryLog.executions(log, :p_blob) == [:a]
      QueryLog.stop(log)
      assert Memo.changed_at(second.db, {:p_blob, :a}) == {:ok, changed_at}
      assert Dependencies.status(second.db, {:p_blob, :a}) == :clean
      Input.set(second.db, :psrc, :a, 2)
      assert PersistQueries.p_blob(second.db, :a) == 2
    after
      Session.close(second)
    end
  end

  test "entity databases use ordinary field validation", %{db: db} do
    Database.register_entity(db, Roux.Test.SampleEntity)
    Input.set(db, :source, :a, 1)

    producer = fn db, key ->
      Runtime.create(db, Roux.Test.SampleEntity, %{
        name: key,
        body: Runtime.input(db, :source, key),
        return_type: :integer
      })
    end

    reader = fn db, key ->
      id = Runtime.execute(db, :entity_producer, key, producer)
      Runtime.field(db, Roux.Test.SampleEntity, id, :body)
    end

    assert Runtime.execute(db, :entity_reader, :a, reader) == 1
    assert Dependencies.status(db, {:entity_reader, :a}) == :disabled
    Input.set(db, :source, :a, 2)
    assert Runtime.execute(db, :entity_reader, :a, reader) == 2
  end

  test "a delayed child cannot publish a new value under an old revision", %{db: db} do
    Input.set(db, :source, :a, 1)
    leaf = fn db, key -> Runtime.input(db, :source, key) end
    parent = fn db, key -> Runtime.execute(db, :delayed_leaf, key, leaf) end
    assert Runtime.execute(db, :delayed_parent, :a, parent) == 1
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:roux, :query, :start],
      fn _, _, metadata, _ ->
        if metadata.database == Database.id(db) and metadata.query_name == :delayed_leaf do
          send(test_pid, {:starting_child, self()})

          receive do
            :continue_child -> :ok
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    writer =
      Task.async(fn ->
        Dependencies.mutate(db, {:input, :source, :a}, fn ->
          send(test_pid, :writer_started)

          receive do
            :finish_write -> :ok
          end

          revision = Dependencies.advance(db, :medium)
          {:ok, input} = Memo.get(db, {:input, :source, :a})

          Memo.put_input(db, {:input, :source, :a}, %{
            input
            | value: 2,
              hash: :erlang.phash2(2),
              changed_at: revision,
              verified_at: revision
          })
        end)
      end)

    assert_receive :writer_started
    child = Task.async(fn -> Runtime.execute(db, :delayed_leaf, :a, leaf) end)
    assert_receive {:starting_child, child_pid}
    send(writer.pid, :finish_write)
    Task.await(writer)
    :telemetry.detach(handler)
    send(child_pid, :continue_child)
    assert Task.await(child) == 2
    assert Runtime.execute(db, :delayed_parent, :a, parent) == 2
  end

  test "repairing an uncertified child cannot preserve a misleading changed_at", %{db: db} do
    Input.set(db, :source, :a, 1)
    leaf = fn db, key -> Runtime.input(db, :source, key) end
    parent = fn db, key -> Runtime.execute(db, :repair_leaf, key, leaf) end
    assert Runtime.execute(db, :repair_parent, :a, parent) == 1
    test_pid = self()

    writer =
      Task.async(fn ->
        Dependencies.mutate(db, {:input, :source, :a}, fn ->
          send(test_pid, :repair_writer_started)

          receive do
            :finish_write -> :ok
          end

          revision = Dependencies.advance(db, :medium)
          {:ok, input} = Memo.get(db, {:input, :source, :a})

          Memo.put_input(db, {:input, :source, :a}, %{
            input
            | value: 2,
              hash: :erlang.phash2(2),
              changed_at: revision,
              verified_at: revision
          })
        end)
      end)

    assert_receive :repair_writer_started

    child =
      Task.async(fn ->
        Runtime.execute(db, :repair_leaf, :a, fn db, key ->
          send(test_pid, :inside_child_body)

          receive do
            :read_after_write -> :ok
          end

          Runtime.input(db, :source, key)
        end)
      end)

    assert_receive :inside_child_body
    send(writer.pid, :finish_write)
    Task.await(writer)
    send(child.pid, :read_after_write)
    assert Task.await(child) == 2
    assert Dependencies.status(db, {:repair_leaf, :a}) == :stale
    # The interrupted computation began at revision 1. Its replacement must
    # record revision 2 even though executing again returns the same value.
    assert Memo.changed_at(db, {:repair_leaf, :a}) == {:ok, 1}
    assert Runtime.execute(db, :repair_parent, :a, parent) == 2
    assert Memo.changed_at(db, {:repair_leaf, :a}) == {:ok, 2}
  end

  test "edits collect edges left by a killed publisher", %{db: db} do
    dependency = {:input, :source, :a}
    key = {:abandoned, :a}
    generation = make_ref()
    parent = self()

    publisher =
      spawn(fn ->
        Dependencies.publish(db, key, generation, [dependency], Dependencies.snapshot(db), fn ->
          send(parent, :edges_installed)

          receive do
            :never_finish -> :ok
          end
        end)
      end)

    assert_receive :edges_installed
    assert :ets.lookup(db.dependencies.edges, dependency) == [{dependency, key, generation}]
    monitor = Process.monitor(publisher)
    Process.exit(publisher, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^publisher, :killed}
    Input.set(db, :source, :a, 1)
    assert :ets.lookup(db.dependencies.edges, dependency) == []
    assert :ets.lookup(db.dependencies.nodes, generation) == []
  end

  test "a lost reverse-index table falls back without breaking memo cleanup", %{db: db} do
    Input.set(db, :source, :a, 1)
    query = fn db, key -> Runtime.input(db, :source, key) end
    assert Runtime.execute(db, :lost_index, :a, query) == 1
    gone = :ets.new(:lost_index, [:set])
    :ets.delete(gone)
    db = %{db | dependencies: %{db.dependencies | nodes: gone}}
    assert Dependencies.status(db, {:lost_index, :a}) == :stale
    Input.set(db, :source, :a, 2)
    assert Runtime.execute(db, :lost_index, :a, query) == 2
    assert Memo.delete(db, {:lost_index, :a}) == :ok
    assert Memo.delete_all(db) == :ok
  end

  test "a finished input write wins after concurrent query demands" do
    for _ <- 1..50, do: Roux.Test.ReverseDependencyRace.test()
  end

  @tag :tmp_dir
  test "a manifest cannot turn an uncertified value into a restored proof", %{tmp_dir: dir} do
    opts = [
      modules: [PersistQueries],
      blob: Path.join(dir, "blobs"),
      manifest: Path.join(dir, "manifest"),
      reverse_dependencies: true
    ]

    first = Session.open(opts)
    db = first.db
    Input.set(db, :psrc, :a, 1)
    assert PersistQueries.p_top(db, :a) == {:top, {:read, {:ok, 1}}}
    parent = self()

    writer =
      Task.async(fn ->
        Dependencies.mutate(db, {:input, :psrc, :a}, fn ->
          revision = Dependencies.advance(db, :medium)
          send(parent, :manifest_input_advanced)

          receive do
            :publish_input -> :ok
          end

          {:ok, input} = Memo.get(db, {:input, :psrc, :a})

          Memo.put_input(db, {:input, :psrc, :a}, %{
            input
            | value: 2,
              hash: :erlang.phash2(2),
              changed_at: revision,
              verified_at: revision
          })
        end)
      end)

    assert_receive :manifest_input_advanced
    # The old input remains visible after the revision has advanced. All three
    # derived entries now hold the old value with verified_at == changed_at of
    # the imminent input write, so restoring them as ordinary proofs is unsafe.
    assert PersistQueries.p_top(db, :a) == {:top, {:read, {:ok, 1}}}
    send(writer.pid, :publish_input)
    Task.await(writer)
    assert Dependencies.status(db, {:p_top, :a}) == :stale
    assert {:written, _} = Session.commit(first, %{})
    Session.close(first)

    for reverse? <- [true, false] do
      second = Session.open(Keyword.put(opts, :reverse_dependencies, reverse?))

      try do
        assert second.restored?
        assert PersistQueries.p_top(second.db, :a) == {:top, {:read, {:ok, 2}}}
      after
        Session.close(second)
      end
    end
  end

  @tag :tmp_dir
  test "a manifest omits clean readers of uncertified blob owners", %{
    db: db,
    tmp_dir: dir
  } do
    {:ok, store} = Blob.open(Path.join(dir, "held"))
    db = %{db | blob: store}
    Input.set(db, :source, :unrelated, 0)
    Database.register_query(db, :held_child, %{})
    Database.register_query(db, :held_parent, %{})

    child = fn db, _ ->
      {:ok, digest} = Blob.put(db.blob, "retained through the child")
      Runtime.hold(digest)
      digest
    end

    parent = fn db, key -> Runtime.execute(db, :held_child, key, child) end
    digest = Runtime.execute(db, :held_parent, :a, parent)

    Dependencies.mutate(db, {:input, :source, :unrelated}, fn ->
      assert Runtime.execute(db, :held_child, :a, child) == digest
    end)

    assert Dependencies.status(db, {:held_child, :a}) == :stale
    assert Dependencies.status(db, {:held_parent, :a}) == :clean

    manifest = Path.join(dir, "held.manifest")
    Manifest.write(db, %{}, manifest)
    {:ok, data} = Manifest.load(manifest)
    refute Enum.any?(data.memo_entries, &(elem(&1, 0) == {:held_parent, :a}))
    second = Database.new(reverse_dependencies: true, blob: store)

    try do
      Database.register_query(second, :held_child, %{})
      Database.register_query(second, :held_parent, %{})
      Manifest.restore(second, data)
      assert Memo.get(second, {:held_parent, :a}) == :miss
      assert Runtime.execute(second, :held_parent, :a, parent) == digest
    after
      Database.shutdown(second)
    end
  end

  defp owner(db) do
    Enum.find_value(Supervisor.which_children(db.supervisor), fn
      {Roux.Database.TableOwner, pid, :worker, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp wait_for_owner(db, previous, attempts) when attempts > 0 do
    case owner(db) do
      current when is_pid(current) and current != previous ->
        Roux.Database.TableOwner.get_tables(current)

      _ ->
        Process.sleep(5)
        wait_for_owner(db, previous, attempts - 1)
    end
  end

  defp wait_for_owner(_db, _previous, 0), do: flunk("table owner did not restart")
end
