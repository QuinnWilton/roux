defmodule Roux.BlobTest do
  use ExUnit.Case, async: true

  alias Roux.Blob
  alias Roux.Blob.Trace

  @moduletag :tmp_dir

  @day 24 * 60 * 60

  setup %{tmp_dir: tmp} do
    %{store: Blob.open!(Path.join(tmp, "store"))}
  end

  defp age!(path, seconds), do: File.touch!(path, System.os_time(:second) - seconds)

  describe "open/1" do
    test "makes a store, opens it again, and refuses another layout's", %{tmp_dir: tmp} do
      root = Path.join(tmp, "fresh")
      assert {:ok, %Blob{root: ^root}} = Blob.open(root)
      assert File.read!(Path.join(root, "FORMAT")) == "roux-blob 1\n"
      assert {:ok, _} = Blob.open(root)

      format = Path.join(root, "FORMAT")
      File.chmod!(format, 0o644)
      File.write!(format, "roux-blob 0\n")
      assert {:error, {:format, "roux-blob 0\n"}} = Blob.open(root)
      assert_raise Roux.Blob.FormatError, ~r/another layout/, fn -> Blob.open!(root) end
    end

    test "a temporary store is its own, and destroy removes it" do
      store = Blob.temporary()
      assert store.temporary?
      assert {:ok, digest} = Blob.put(store, "x")
      assert {:ok, "x"} = Blob.get(store, digest)
      assert :ok = Blob.destroy(store)
      refute File.exists?(store.root)
    end
  end

  describe "the content-addressed entries" do
    test "put names bytes by their SHA-256, and get reads them back", %{store: store} do
      assert {:ok, digest} = Blob.put(store, ["hel", "lo"])
      assert digest == :sha256 |> :crypto.hash("hello") |> Base.encode16(case: :lower)
      assert {:ok, "hello"} = Blob.get(store, digest)
      assert {:ok, ^digest} = Blob.put(store, "hello")
      assert Blob.member?(store, digest)

      # Read-only on disk: a link to it cannot write into the store.
      assert {:ok, %File.Stat{mode: mode}} = File.stat(Blob.path(store, digest))
      assert Bitwise.band(mode, 0o222) == 0
    end

    test "a missing entry is a miss; fetch! raises naming it", %{store: store} do
      digest = Blob.digest("never stored")
      assert Blob.get(store, digest) == :miss
      assert Blob.get_term(store, digest) == :miss
      assert_raise Roux.Blob.MissingError, ~r/#{digest}/, fn -> Blob.fetch!(store, digest) end
    end

    test "a corrupt entry is a miss, and is taken out of its name", %{store: store} do
      {:ok, digest} = Blob.put(store, "the real bytes")
      path = Blob.path(store, digest)
      File.chmod!(path, 0o644)
      File.write!(path, "the real bytez")

      assert Blob.get(store, digest) == :miss
      refute File.exists?(path)
      assert {:ok, ^digest} = Blob.put(store, "the real bytes")
      assert {:ok, "the real bytes"} = Blob.get(store, digest)
    end

    test "put_term encodes deterministically; get_term decodes what it stored", %{store: store} do
      a = Map.new(1..40, &{&1, Integer.to_string(&1)})
      b = 40..1//-1 |> Enum.map(&{&1, Integer.to_string(&1)}) |> Map.new()

      assert {:ok, digest} = Blob.put_term(store, a)
      assert {:ok, ^digest} = Blob.put_term(store, b)
      assert {digest, _bytes} = Blob.encode_term(b)
      assert {:ok, ^a} = Blob.get_term(store, digest)

      {:ok, not_a_term} = Blob.put(store, "not a term")
      assert Blob.get_term(store, not_a_term) == :miss

      # An atom this VM never saw is made, as the manifest makes it (the
      # store is trusted: see Roux.Blob.TrustTest).
      name = "roux_blob_test_#{System.unique_integer([:positive])}"
      unknown = <<131, 119, byte_size(name)::8, name::binary>>
      {:ok, atom_digest} = Blob.put(store, unknown)
      assert {:ok, atom} = Blob.get_term(store, atom_digest)
      assert Atom.to_string(atom) == name

      # A truncated term is still a miss.
      {:ok, cut} = Blob.put(store, binary_part(unknown, 0, byte_size(unknown) - 2))
      assert Blob.get_term(store, cut) == :miss
    end

    test "adopt moves a file in by rename", %{store: store, tmp_dir: tmp} do
      Blob.scratch(store, fn dir ->
        file = Path.join(dir, "out.csv")
        File.write!(file, "a\tb\n")
        assert {:ok, digest} = Blob.adopt(store, file)
        refute File.exists?(file)
        assert {:ok, "a\tb\n"} = Blob.get(store, digest)

        # The same bytes again: the entry stays, the file goes.
        File.write!(file, "a\tb\n")
        assert {:ok, ^digest} = Blob.adopt(store, file)
        refute File.exists?(file)
      end)

      assert {:error, :enoent} = Blob.adopt(store, Path.join(tmp, "nothing"))
    end

    test "link makes a hard link, never a symbolic one", %{store: store} do
      {:ok, digest} = Blob.put(store, "shared")

      Blob.scratch(store, fn dir ->
        dest = Path.join(dir, "input.facts")
        assert :ok = Blob.link(store, digest, dest)
        assert {:ok, %File.Stat{type: :regular}} = File.lstat(dest)
        assert File.stat!(dest).inode == File.stat!(Blob.path(store, digest)).inode
        assert File.read!(dest) == "shared"

        assert {:error, :missing} = Blob.link(store, Blob.digest("absent"), Path.join(dir, "x"))
        assert {:error, :eexist} = Blob.link(store, digest, dest)
      end)
    end
  end

  describe "the action cache" do
    test "remembers any term under any key", %{store: store} do
      key = {:solve, %{program: "p", inputs: ["a", "b"]}}
      assert Blob.recall(store, key) == :miss
      assert :ok = Blob.remember(store, key, {:outputs, [1, 2]})
      assert {:ok, {:outputs, [1, 2]}} = Blob.recall(store, key)
      assert Blob.recall(store, {:solve, %{}}) == :miss
    end

    test "cached keeps a value, and never an error", %{store: store} do
      counter = :counters.new(1, [])

      compute = fn value ->
        fn ->
          :counters.add(counter, 1, 1)
          value
        end
      end

      assert Blob.cached(store, :ok_key, compute.({:ok, 1})) == {:ok, 1}
      assert Blob.cached(store, :ok_key, compute.({:ok, 2})) == {:ok, 1}
      assert Blob.cached(store, :err_key, compute.({:error, :boom})) == {:error, :boom}
      assert Blob.cached(store, :err_key, compute.(:error)) == :error
      assert Blob.cached(store, :err_key, compute.(:fine)) == :fine
      assert :counters.get(counter, 1) == 4
    end
  end

  describe "traces" do
    test "find returns a value whose observations still hold", %{store: store} do
      :ok = Trace.put(store, :parse, [{:a, 1}, {:b, 2}], :parsed_one)
      :ok = Trace.put(store, :parse, [{:a, 3}, {:b, 2}], :parsed_three)

      assert {:ok, :parsed_one} = Trace.find(store, :parse, &%{a: 1, b: 2}[&1])
      assert {:ok, :parsed_three} = Trace.find(store, :parse, &%{a: 3, b: 2}[&1])
      assert Trace.find(store, :parse, &%{a: 1, b: 9}[&1]) == :miss
      assert Trace.find(store, :other, fn _ -> 1 end) == :miss
      assert length(Trace.fetch(store, :parse)) == 2
    end

    test "each observation is made once per find", %{store: store} do
      for n <- 1..5, do: :ok = Trace.put(store, :t, [{:shared, 0}, {:own, n}], n)
      counter = :counters.new(1, [])

      observe = fn
        :shared ->
          :counters.add(counter, 1, 1)
          0

        :own ->
          3
      end

      assert {:ok, 3} = Trace.find(store, :t, observe)
      assert :counters.get(counter, 1) == 1

      traces = Trace.fetch(store, :t)
      assert {:ok, 3} = Trace.find(traces, :t, observe)
    end
  end

  describe "trace history" do
    defp trace_files(store, name) do
      Path.wildcard(Path.join([store.root, "traces", Blob.term_digest(name), "*"]))
    end

    defp backdate!(store, name, deps, age) do
      path = Path.join([store.root, "traces", Blob.term_digest(name), Blob.term_digest(deps)])
      File.touch!(path, System.os_time(:second) - age)
    end

    # How many files the calling process read during `fun`: its raw calls
    # to `:file.read_file/2` (`Roux.Blob.IO`), traced for this process
    # alone (other tests' reads do not count) and counted by a tracer of
    # its own (a process cannot be its own tracer).
    defp reads_during(fun) do
      collector = spawn_link(fn -> collect_reads(0) end)
      :erlang.trace_pattern({:file, :read_file, 2}, true, [])
      :erlang.trace(self(), true, [:call, {:tracer, collector}])

      result =
        try do
          fun.()
        after
          :erlang.trace(self(), false, [:call])
        end

      # Every trace message this process caused has reached the tracer.
      ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^ref}
      send(collector, {:count, self()})
      assert_receive {:reads, reads}
      {result, reads}
    end

    defp collect_reads(n) do
      receive do
        {:trace, _pid, :call, {:file, :read_file, _args}} -> collect_reads(n + 1)
        {:count, from} -> send(from, {:reads, n})
      end
    end

    test "a name keeps its most recent traces, however many are put", %{store: store} do
      for n <- 1..30, do: :ok = Trace.put(store, :bounded, [{:n, n}], n)
      assert length(trace_files(store, :bounded)) == 8

      for n <- 1..5, do: :ok = Trace.put(store, :three, [{:n, n}], n, keep: 3)
      assert length(trace_files(store, :three)) == 3
      assert {:ok, 5} = Trace.find(store, :three, fn :n -> 5 end)

      for n <- 1..12, do: :ok = Trace.put(store, :all, [{:n, n}], n, keep: :infinity)
      assert length(trace_files(store, :all)) == 12

      assert_raise ArgumentError, fn -> Trace.put(store, :bad, [], 1, keep: 0) end
    end

    test "most recently used means used: a trace found survives the next prune", %{
      store: store
    } do
      # Last used hours ago: longer than the store's refresh interval.
      for {n, age} <- [{1, 4 * 3600}, {2, 3 * 3600}, {3, 2 * 3600}] do
        :ok = Trace.put(store, :lru, [{:n, n}], n, keep: 3)
        backdate!(store, :lru, [{:n, n}], age)
      end

      # The oldest, used now.
      assert {:ok, 1} = Trace.find(store, :lru, fn :n -> 1 end)
      :ok = Trace.put(store, :lru, [{:n, 4}], 4, keep: 3)

      kept = store |> Trace.fetch(:lru) |> Enum.map(& &1.value) |> Enum.sort()
      assert kept == [1, 3, 4]
    end

    test "limit reads the most recently used, whatever the history's length", %{store: store} do
      big = :binary.copy("x", 20_000)

      for {name, count} <- [short: 10, long: 200] do
        for n <- 1..count do
          :ok = Trace.put(store, name, [{:n, n}], {n, big}, keep: :infinity)
          backdate!(store, name, [{:n, n}], 1_000 - n)
        end
      end

      for name <- [:short, :long] do
        {traces, reads} = reads_during(fn -> Trace.fetch(store, name, limit: 4) end)
        assert reads == 4
        assert length(traces) == 4

        # The newest first: the last four put.
        count = length(trace_files(store, name))
        assert Enum.map(traces, &elem(&1.value, 0)) == Enum.to_list(count..(count - 3)//-1)
      end

      {_traces, all} = reads_during(fn -> Trace.fetch(store, :long) end)
      assert all == 200

      # A find looks among the same few: a hit beyond them is a miss.
      {hit, reads} = reads_during(fn -> Trace.find(store, :long, fn :n -> 199 end, limit: 4) end)
      assert {:ok, {199, _}} = hit
      assert reads == 4
      assert Trace.find(store, :long, fn :n -> 1 end, limit: 4) == :miss
      assert {:ok, {1, _}} = Trace.find(store, :long, fn :n -> 1 end)
    end
  end

  describe "refreshing on a hit" do
    defp mtime(path), do: File.stat!(path, time: :posix).mtime

    defp age!(path, seconds), do: File.touch!(path, System.os_time(:second) - seconds)

    test "leaves an entry used within the refresh interval alone, and marks an older one",
         %{store: store} do
      {:ok, digest} = Blob.put(store, "bytes")
      :ok = Blob.remember(store, :key, :value)
      :ok = Trace.put(store, :name, [{:n, 1}], :traced)
      cas = Blob.path(store, digest)
      [ac] = Path.wildcard(Path.join([store.root, "ac", "*", "*"]))
      [trace] = Path.wildcard(Path.join([store.root, "traces", "*", "*"]))

      hit = fn ->
        {:ok, ^digest} = Blob.put(store, "bytes")
        {:ok, :value} = Blob.recall(store, :key)
        {:ok, :traced} = Trace.find(store, :name, fn :n -> 1 end)
      end

      # Ten minutes ago: within the hour, so a hit writes nothing.
      for path <- [cas, ac, trace], do: age!(path, 600)
      before = Enum.map([cas, ac, trace], &mtime/1)
      hit.()
      assert Enum.map([cas, ac, trace], &mtime/1) == before

      # Two hours ago: a hit marks each used now.
      for path <- [cas, ac, trace], do: age!(path, 2 * 3600)
      hit.()
      now = System.os_time(:second)
      for path <- [cas, ac, trace], do: assert(now - mtime(path) < 60)
    end

    test "with refresh: 0, every hit marks", %{tmp_dir: tmp} do
      store = Blob.open!(Path.join(tmp, "eager"), refresh: 0)
      :ok = Blob.remember(store, :key, :value)
      [ac] = Path.wildcard(Path.join([store.root, "ac", "*", "*"]))
      age!(ac, 30)
      {:ok, :value} = Blob.recall(store, :key)
      assert System.os_time(:second) - mtime(ac) < 30
      assert_raise ArgumentError, fn -> Blob.open(Path.join(tmp, "bad"), refresh: -1) end
    end

    test "a collection's grace is never shorter than the refresh interval", %{store: store} do
      # Twenty minutes old and named by nothing: a grace of zero would take
      # it, though a hit within the hour may have left its time alone.
      {:ok, digest} = Blob.put(store, "recent enough")
      age!(Blob.path(store, digest), 1200)
      Blob.gc(store, grace: 0, keep: 0)
      assert Blob.member?(store, digest)
    end
  end

  describe "never replacing what readers count on" do
    defp inode(path), do: File.stat!(path).inode

    test "a CAS entry written again keeps its inode: it is never replaced", %{store: store} do
      {:ok, digest} = Blob.put(store, "same")
      path = Blob.path(store, digest)
      before = inode(path)

      # Found missing by a writer that races another: the link loses to
      # the entry there, which stays.
      Blob.scratch(store, fn dir ->
        output = Path.join(dir, "out")
        File.write!(output, "same")
        assert {:ok, ^digest} = Blob.adopt(store, output)
        refute File.exists?(output)
      end)

      assert inode(path) == before
    end

    test "an equal action-cache value, trace or root is not written again", %{
      store: store,
      tmp_dir: tmp
    } do
      :ok = Blob.remember(store, :k, :v)
      :ok = Trace.put(store, :t, [{:a, 1}], :v)
      owner = Path.join(tmp, "owner")
      File.write!(owner, "")
      :ok = Blob.retain(store, owner, ["d"])

      files =
        for dir <- ["ac", "traces", "roots"],
            path <- Path.wildcard(Path.join([store.root, dir, "**"])),
            File.regular?(path),
            do: path

      before = Map.new(files, &{&1, inode(&1)})

      :ok = Blob.remember(store, :k, :v)
      :ok = Trace.put(store, :t, [{:a, 1}], :v)
      :ok = Blob.retain(store, owner, ["d"])
      assert Map.new(files, &{&1, inode(&1)}) == before

      # A changed value is written.
      :ok = Blob.remember(store, :k, :w)
      assert {:ok, :w} = Blob.recall(store, :k)
    end

    test "a collection that cannot read a root it listed sweeps nothing", %{store: store} do
      {:ok, digest} = Blob.put(store, "unnamed and old")
      age!(Blob.path(store, digest), 2 * @day)
      File.mkdir_p!(Path.join(store.root, "roots"))
      File.write!(Path.join([store.root, "roots", "unreadable"]), "not a root")

      assert %{removed: 0} = Blob.gc(store)
      assert Blob.member?(store, digest)
    end
  end

  describe "scratch/2" do
    test "hands out a directory of its own, removed afterwards", %{store: store} do
      dir = Blob.scratch(store, fn dir -> File.dir?(dir) && dir end)
      assert is_binary(dir)
      refute File.exists?(dir)

      assert_raise RuntimeError, fn ->
        Blob.scratch(store, fn dir ->
          Process.put(:scratch_dir, dir)
          raise "inside"
        end)
      end

      refute File.exists?(Process.get(:scratch_dir))
    end
  end

  describe "gc/2" do
    test "sweeps old entries no root names, and keeps the rest", %{store: store, tmp_dir: tmp} do
      owner = Path.join(tmp, "manifest")
      File.write!(owner, "")
      {:ok, kept} = Blob.put(store, "retained")
      {:ok, pointed} = Blob.put(store, "named by a recent action")
      {:ok, old_pointed} = Blob.put(store, "named by an old action")
      {:ok, young} = Blob.put(store, "written just now")
      {:ok, old} = Blob.put(store, "old and unnamed")

      :ok = Blob.retain(store, owner, [kept])
      :ok = Blob.remember(store, :recent, %{outputs: [pointed]})
      :ok = Blob.remember(store, :stale, [old_pointed])
      ac = Path.join([store.root, "ac"])

      stale =
        for aa <- File.ls!(ac), name <- File.ls!(Path.join(ac, aa)), do: Path.join([ac, aa, name])

      stale_ac =
        Enum.find(stale, &(Blob.decode(File.read!(&1)) == {:ok, {:stale, [old_pointed]}}))

      age!(stale_ac, 8 * @day)

      for digest <- [kept, pointed, old_pointed, old],
          do: age!(Blob.path(store, digest), 2 * @day)

      stats = Blob.gc(store)

      assert Blob.member?(store, kept)
      assert Blob.member?(store, pointed)
      assert Blob.member?(store, young)
      refute Blob.member?(store, old)
      refute Blob.member?(store, old_pointed)
      assert Blob.recall(store, :stale) == :miss
      assert {:ok, _} = Blob.recall(store, :recent)
      assert stats.removed == 3

      # The owner gone, its roots go with it — once not retained for the
      # grace period (a manifest being rewritten is missing for a moment).
      File.rm!(owner)
      age!(Blob.path(store, kept), 2 * @day)
      Blob.gc(store)
      assert Blob.member?(store, kept)

      for root <- Path.wildcard(Path.join([store.root, "roots", "*"])), do: age!(root, 2 * @day)
      Blob.gc(store)
      refute Blob.member?(store, kept)
    end

    test "removes what a dead process left behind a day ago", %{store: store} do
      left = Path.join([store.root, "scratch", "99999-1"])
      File.mkdir_p!(left)
      age!(left, 2 * @day)
      fresh = Path.join([store.root, "scratch", "99999-2"])
      File.mkdir_p!(fresh)

      Blob.gc(store)
      refute File.exists?(left)
      assert File.exists?(fresh)
    end

    test "maybe_gc collects at most once per period", %{store: store} do
      assert {:ok, %{removed: 0}} = Blob.maybe_gc(store)
      assert Blob.maybe_gc(store) == :skipped
      age!(Path.join(store.root, "gc.stamp"), 10)
      assert {:ok, _} = Blob.maybe_gc(store, every: 5)
    end
  end
end
