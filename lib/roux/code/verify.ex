defmodule Roux.Code.Verify do
  @moduledoc """
  What a computation actually runs, for a test that checks a closure
  (`Roux.Code.closure/2`) against it: every module the computation
  executes must be in the closure of the roots its code version is
  made of, or an edit to that module would leave stale results in
  place.

      {_result, ran} = Roux.Code.Verify.executed(fn -> MyGraph.extract(db, key) end)
      {:ok, closure} = Roux.Code.closure([MyGraph.Extraction])
      assert ran -- Enum.map(closure, &elem(&1, 0)) == []

  `executed/2` counts one run. A test that counts many turns counting
  on once (`counting/2`), since turning it on and off again for a few
  hundred modules takes a fraction of a second, and reads each run with
  the counts set back to zero (`calls/2`), which takes a few
  milliseconds:

      Roux.Code.Verify.counting(fn session ->
        for key <- keys do
          {_result, calls} = Roux.Code.Verify.calls(session, fn -> MyGraph.extract(db, key) end)
          {key, Roux.Code.Verify.modules(calls)}
        end
      end)

  Call counts are kept per VM, not per process: anything else the VM
  runs meanwhile counts too. Run it in a VM of its own (`:peer`). Two
  sessions in one VM take turns (`counting/2` waits for the other to
  end), since setting the counts back to zero sets every session's.
  """

  defmodule Session do
    @moduledoc """
    A counting session (`Roux.Code.Verify.counting/2`): the modules
    whose functions it counts.
    """

    @enforce_keys [:modules]
    defstruct [:modules]

    @type t :: %__MODULE__{modules: [module()]}
  end

  defmodule UncountedError do
    @moduledoc """
    Raised by `Roux.Code.Verify.calls/2` for modules of the session that
    are no longer counted: loaded again during the session, which drops
    their counters, or counting turned off by something other than the
    session. Reading them would take every function in them for one
    never called.
    """

    @type t :: %__MODULE__{modules: [module()]}

    defexception [:modules]

    @impl true
    def message(%__MODULE__{modules: modules}) do
      "the counting session no longer counts #{inspect(modules)}: " <>
        "loaded again or uncounted during the session"
    end
  end

  # Functions every module has that a run's calls never include: the
  # session reads `module_info/0`'s counter to see a module is still
  # counted, and reads each module's functions through `module_info/1`.
  @uncounted [:module_info, :__info__]

  @doc """
  Runs `fun` with call counting on, and returns its result with the
  modules it called into, sorted.

  ## Options

    * `:modules` — the modules to watch (default: every module of every
      loaded application that is not OTP's or Elixir's). A module is
      loaded before the run, since only loaded code can be counted.
  """
  @spec executed((-> result), keyword()) :: {result, [module()]} when result: var
  def executed(fun, opts \\ []) when is_function(fun, 0) do
    # A session's counters start at zero, so the run needs no reset.
    {result, calls} = counting(fn session -> read(session, fun) end, opts)
    {result, modules(calls)}
  end

  @doc """
  Runs `fun` with every function of the watched modules counted, and
  stops counting after: its result. `fun` takes the session, to read
  runs within it with `calls/2`.

  Sessions in one VM take turns: one opened while another process's is
  open waits for it to end. A process does not wait for its own, so do
  not open a session within another: the inner one would turn counting
  off for the outer one's modules when it ends.

  ## Options

    * `:modules` — the modules to watch, as for `executed/2`.
  """
  @spec counting((Session.t() -> result), keyword()) :: result when result: var
  def counting(fun, opts \\ []) when is_function(fun, 1) do
    modules = Keyword.get_lazy(opts, :modules, &project_modules/0)
    Enum.each(modules, &Code.ensure_loaded/1)
    session = %Session{modules: Enum.filter(modules, &:erlang.module_loaded/1)}

    :global.trans(
      {__MODULE__, self()},
      fn ->
        Enum.each(session.modules, &:erlang.trace_pattern({&1, :_, :_}, true, [:call_count]))

        try do
          fun.(session)
        after
          Enum.each(session.modules, &:erlang.trace_pattern({&1, :_, :_}, false, [:call_count]))
        end
      end,
      [node()],
      :infinity
    )
  end

  @doc """
  Runs `fun` within `session`, with every count set back to zero first:
  its result, and the functions of the session's modules it called, each
  with how often, among those still counted (see `ignore/2`).

  Raises `Roux.Code.Verify.UncountedError` when a module of the session
  is no longer counted at all.
  """
  @spec calls(Session.t(), (-> result)) :: {result, %{mfa() => pos_integer()}} when result: var
  def calls(%Session{} = session, fun) when is_function(fun, 0) do
    # Every counter in the VM at once: a few milliseconds, where setting
    # each module's apart takes as long as turning counting on.
    :erlang.trace_pattern({:_, :_, :_}, :restart, [:call_count])
    read(session, fun)
  end

  @doc """
  Stops counting `functions` for the rest of `session`: hot functions,
  already known to be called, whose counter every worker bumps at once.
  A run reads them as not called.
  """
  @spec ignore(Session.t(), [mfa()]) :: :ok
  def ignore(%Session{}, functions) when is_list(functions) do
    for {_module, name, _arity} = mfa <- functions, name not in @uncounted do
      :erlang.trace_pattern(mfa, false, [:call_count])
    end

    :ok
  end

  @doc "The modules among `calls/2`'s functions, sorted."
  @spec modules(%{mfa() => pos_integer()}) :: [module()]
  def modules(calls) when is_map(calls) do
    calls |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
  end

  defp read(session, fun) do
    result = fun.()

    case Enum.reject(session.modules, &counted?/1) do
      [] -> {result, called(session)}
      uncounted -> raise UncountedError, modules: uncounted
    end
  end

  defp counted?(module), do: counter({module, :module_info, 0}) != :uncounted

  defp called(session) do
    for module <- session.modules,
        {name, arity} <- module.module_info(:functions),
        name not in @uncounted,
        mfa = {module, name, arity},
        {:counted, calls} <- [counter(mfa)],
        calls > 0,
        into: %{},
        do: {mfa, calls}
  end

  # A function not counted reads `false`, which compares above every
  # number: `n > 0` alone takes it for called. One that no longer
  # exists (its module unloaded) reads `undefined`, another atom.
  defp counter(mfa) do
    case :erlang.trace_info(mfa, :call_count) do
      {:call_count, calls} when is_integer(calls) -> {:counted, calls}
      {:call_count, absent} when absent in [false, :undefined] -> :uncounted
    end
  end

  defp project_modules do
    root = List.to_string(:code.root_dir())

    for {app, _description, _vsn} <- Application.loaded_applications(),
        app not in [:elixir, :eex, :ex_unit, :iex, :logger, :mix],
        not otp_app?(app, root),
        mod <- Application.spec(app, :modules) || [],
        do: mod
  end

  defp otp_app?(app, root) do
    case :code.lib_dir(app) do
      {:error, _} -> false
      dir -> String.starts_with?(List.to_string(dir), root)
    end
  end
end
