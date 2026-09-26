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

  Call counts are kept per VM, not per process: anything else the VM
  runs meanwhile counts too. Run it in a VM of its own (`:peer`).
  """

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
    modules = Keyword.get_lazy(opts, :modules, &project_modules/0)
    Enum.each(modules, &Code.ensure_loaded/1)
    watched = Enum.filter(modules, &:erlang.module_loaded/1)

    for mod <- watched, do: :erlang.trace_pattern({mod, :_, :_}, true, [:call_count])

    try do
      result = fun.()
      {result, Enum.filter(watched, &called?/1)}
    after
      for mod <- watched, do: :erlang.trace_pattern({mod, :_, :_}, false, [:call_count])
    end
  end

  defp called?(mod) do
    Enum.any?(mod.module_info(:functions), fn {f, a} ->
      f not in [:module_info, :__info__] and
        match?({:call_count, n} when n > 0, :erlang.trace_info({mod, f, a}, :call_count))
    end)
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
