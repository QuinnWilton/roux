defmodule Roux.Dependencies do
  @moduledoc """
  Reverse edges for skipping validation of unaffected queries.

  Inputs mark transitive readers as potentially stale; ordinary ordered
  validation still decides whether they need to execute. Clean certificates
  belong to one memo incarnation and a stable mutation epoch. Edges are added
  before publication, and old edges are removed only after their replacement.

  The index is ephemeral. Restored entries acquire certificates on demand.
  Databases with registered entity types use ordinary validation: field readers
  need producer ownership tracking before they can use this shortcut safely.
  """

  alias Roux.{Database, Memo, Revision}

  @type t :: %__MODULE__{
          edges: :ets.tid(),
          nodes: :ets.tid(),
          dirty: :ets.tid(),
          writers: :ets.tid(),
          clock: :atomics.atomics_ref()
        }
  @type token :: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  defstruct [:edges, :nodes, :dirty, :writers, :clock]

  @doc false
  @spec new(map()) :: t()
  def new(tables) do
    %__MODULE__{
      edges: tables.dependency_edges,
      nodes: tables.dependency_nodes,
      dirty: tables.dependency_dirty,
      writers: tables.dependency_writers,
      clock: :atomics.new(2, signed: false)
    }
  end

  @doc false
  @spec snapshot(Database.t()) :: token()
  def snapshot(%Database{dependencies: nil}), do: nil

  def snapshot(%Database{dependencies: index} = db) do
    if :ets.info(db.entity_registry, :size) == 0 and
         :ets.info(index.edges, :size) != :undefined do
      before = clock(db)
      reap(index)
      if :ets.info(index.writers, :size) == 0 and clock(db) == before, do: before
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  @spec status(Database.t(), Memo.query_key()) :: :clean | :check | :stale | :disabled
  def status(%Database{dependencies: nil}, _key), do: :disabled

  def status(db, key) do
    if :ets.info(db.entity_registry, :size) != 0 do
      :disabled
    else
      clean_status(db, key)
    end
  end

  @doc false
  @spec persistable?(Database.t(), Memo.query_key(), reference() | nil) :: boolean()
  def persistable?(%Database{dependencies: nil}, _key, _generation), do: true
  def persistable?(_db, {:input, _, _}, _generation), do: true

  def persistable?(db, key, generation) do
    status(db, key) != :stale and Memo.generation(db, key) == generation
  end

  defp clean_status(%Database{dependencies: index} = db, key) do
    with {unknown, reset, _epoch} = now <- snapshot(db),
         generation when is_reference(generation) <- Memo.generation(db, key),
         [{^generation, ^key, certificate, _deps, _owner}] <- :ets.lookup(index.nodes, generation),
         ^generation <- Memo.generation(db, key),
         dirty <- -:ets.lookup_element(index.dirty, key, 2, 0),
         ^now <- clock(db) do
      case certificate do
        {^unknown, ^reset, certified} when certified >= dirty -> :clean
        {^unknown, ^reset, _certified} -> :check
        {:restored, ^unknown, ^reset} -> :check
        _ -> :stale
      end
    else
      _ -> :stale
    end
  rescue
    ArgumentError -> :stale
  end

  @doc false
  @spec mutate(Database.t(), Memo.query_key() | :all, (-> result)) :: result when result: term()
  def mutate(%Database{dependencies: nil}, _key, run), do: run.()

  def mutate(%Database{dependencies: index} = db, key, run) do
    mutate_with(
      db,
      fn epoch ->
        if key == :all, do: :atomics.add(index.clock, 2, 1), else: mark(db, [key], epoch, %{})
      end,
      run
    )
  end

  @doc false
  @spec change_code(Database.t(), atom(), (-> result)) :: result when result: term()
  def change_code(%Database{dependencies: nil}, _name, run), do: run.()

  def change_code(db, name, run) do
    mutate_with(
      db,
      fn epoch ->
        keys =
          Memo.reduce_dependencies(db, [], fn
            {^name, _argument} = key, _deps, keys -> [key | keys]
            _key, _deps, keys -> keys
          end)

        # A cached aggregate can observe code without executing that query.
        mark(db, [{:query_code, name} | keys], epoch, %{})
      end,
      run
    )
  end

  defp mutate_with(%Database{dependencies: index}, invalidate, run) do
    if available?(index) do
      writer = {make_ref(), self()}
      :ets.insert(index.writers, writer)

      try do
        epoch = :atomics.add_get(index.clock, 1, 1)
        invalidate.(epoch)
        run.()
      after
        :ets.delete_object(index.writers, writer)
      end
    else
      :atomics.add(index.clock, 2, 1)
      run.()
    end
  end

  @doc false
  @spec advance(Database.t(), Revision.durability()) :: Revision.revision()
  def advance(%Database{dependencies: nil} = db, level), do: Revision.advance(db.revision, level)
  def advance(db, level), do: Revision.advance_tracked(db.revision, level)

  @doc false
  @spec publish(
          Database.t(),
          Memo.query_key(),
          reference() | nil,
          [Memo.dependency()],
          token() | :restored,
          (-> result)
        ) :: result
        when result: term()
  def publish(%Database{dependencies: nil}, _key, _generation, _deps, _token, write), do: write.()

  def publish(%Database{dependencies: index} = db, key, generation, deps, token, write) do
    if available?(index) do
      publish_indexed(db, key, generation, deps, token, write)
    else
      write.()
    end
  end

  defp publish_indexed(%Database{dependencies: index} = db, key, generation, deps, token, write) do
    previous = :ets.lookup(index.nodes, Memo.generation(db, key))
    deps = deps |> Enum.flat_map(&keys/1) |> Enum.uniq()
    node = {generation, key, nil, deps, self()}
    :ets.insert(index.nodes, node)

    try do
      Enum.each(deps, &:ets.insert(index.edges, {&1, key, generation}))
      result = write.()
      :ets.update_element(index.nodes, generation, [{3, certificate(db, token)}, {5, nil}])
      Enum.each(previous, &remove_node(index, &1))
      result
    after
      if Memo.generation(db, key) != generation, do: remove_node(index, node)
    end
  end

  defp remove_node(index, {generation, key, _certificate, deps, _owner}) do
    Enum.each(deps, &:ets.delete_object(index.edges, {&1, key, generation}))
    :ets.delete(index.nodes, generation)
  end

  defp certificate(db, :restored) do
    {unknown, reset, _epoch} = clock(db)
    {:restored, unknown, reset}
  end

  defp certificate(db, token) do
    if token != nil and snapshot(db) == token, do: token
  end

  @doc false
  @spec certify(Database.t(), Memo.query_key(), reference() | nil, token()) :: :ok
  def certify(_db, _key, _generation, nil), do: :ok

  def certify(%Database{dependencies: index} = db, key, generation, token) do
    if snapshot(db) == token and Memo.generation(db, key) == generation do
      :ets.select_replace(index.nodes, [
        {{generation, :"$1", :_, :"$2", :"$3"}, [],
         [{{{:const, generation}, :"$1", {:const, token}, :"$2", :"$3"}}]}
      ])
    end

    :ok
  end

  @doc false
  @spec forget(Database.t(), Memo.query_key()) :: :ok
  def forget(%Database{dependencies: nil}, _key), do: :ok

  def forget(%Database{dependencies: index} = db, key) do
    generation = Memo.generation(db, key)

    Enum.each(:ets.lookup(index.nodes, generation), &remove_node(index, &1))
    :ets.delete(index.dirty, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @spec clear(Database.t()) :: :ok
  def clear(%Database{dependencies: nil}), do: :ok

  def clear(%Database{dependencies: index}) do
    for table <- [index.edges, index.nodes, index.dirty],
        :ets.info(table, :size) != :undefined,
        do: :ets.delete_all_objects(table)

    :ok
  end

  defp clock(%Database{dependencies: index, revision: revision}) do
    {Revision.untracked(revision), :atomics.get(index.clock, 2), :atomics.get(index.clock, 1)}
  end

  defp available?(index) do
    Enum.all?([index.edges, index.nodes, index.dirty, index.writers], fn table ->
      :ets.info(table, :size) != :undefined
    end)
  end

  # A killed mutation can leave incomplete propagation. Forget every certificate
  # before removing its barrier; queries recover through ordinary validation.
  defp reap(index) do
    if :ets.info(index.writers, :size) != 0 do
      for {_ref, pid} = writer <- :ets.tab2list(index.writers), not Process.alive?(pid) do
        :atomics.add(index.clock, 2, 1)
        :ets.delete_object(index.writers, writer)
      end
    end
  end

  defp mark(_db, [], _epoch, _seen), do: :ok

  defp mark(%Database{dependencies: index} = db, [key | rest], epoch, seen) do
    if Map.has_key?(seen, key) do
      mark(db, rest, epoch, seen)
    else
      dirty(index.dirty, key, epoch)

      readers =
        for {^key, reader, generation} <- :ets.lookup(index.edges, key),
            active_edge?(db, reader, generation),
            do: reader

      mark(db, readers ++ rest, epoch, Map.put(seen, key, true))
    end
  end

  defp active_edge?(%Database{dependencies: index} = db, key, generation) do
    if Memo.generation(db, key) == generation do
      true
    else
      case :ets.lookup(index.nodes, generation) do
        [{^generation, ^key, _certificate, _deps, owner} = node] ->
          # An in-flight publication needs its edges before its memo exists.
          # A killed publisher's edges can be collected on the next edit.
          if is_pid(owner) and Process.alive?(owner) do
            true
          else
            remove_node(index, node)
            false
          end

        [] ->
          false
      end
    end
  end

  defp dirty(table, key, epoch) do
    # Negative epochs let update_counter's upper threshold implement atomic
    # min, so overlapping writers cannot replace a newer mark with an older one.
    :ets.update_counter(table, key, {2, 0, -epoch, -epoch}, {key, 0})
  end

  defp keys({:input_absent, name, key}), do: [{:input, name, key}]
  defp keys({:query_code, name, _version}), do: [{:query_code, name}]
  defp keys({:parallel, _max, members}), do: Enum.flat_map(members, &keys/1)
  defp keys(key), do: [key]
end
