defmodule Roux.Lang.LSP do
  @moduledoc """
  Generic LSP server that delegates IDE features to query-based language
  implementations. Built on `gen_lsp`.

  The server owns a `Roux.Database` for its session lifetime. IDE features
  (diagnostics, hover, completions, go-to-definition) become queries in the
  same database, sharing cached intermediate results with compilation.

  ## Configuration

      config :roux,
        languages: [MyLang]

  ## File synchronization

  Uses full-text sync (`TextDocumentSyncKind.full()`). Each `didOpen`/`didChange`
  notification sets the source text as an input via `Roux.Input.set/4`, which
  triggers incremental recomputation. Stale in-flight tasks are cancelled via
  `Roux.Cancellation.cancel_dependents/2`. Diagnostics are pushed after a
  configurable debounce period.

  ## Durability limitation

  The subsystem spec describes per-key durability transitions (`:low` while
  editing, `:medium` on save/close). `Roux.Input.set/4` uses the durability
  from the input *definition*, not per-call overrides, so per-key transitions
  are not yet supported. `didClose` restores disk content but does not change
  durability. `didSave` is a no-op. See the spec's note: "the full durability
  model may need per-key durability tracking."

  ## Position mapping

  LSP uses 0-based `{line, character}` positions. Roux languages use 1-based
  `{line, column}`. The adapter handles conversion at the boundary. Languages
  can use `roux_position_to_lsp/1` when building response ranges.
  """

  use GenLSP

  require Logger

  alias Roux.{Cancellation, Database, Input, Lang}

  alias GenLSP.Enumerations.{DiagnosticSeverity, MarkupKind, TextDocumentSyncKind}

  alias GenLSP.Notifications.{
    Exit,
    Initialized,
    TextDocumentDidChange,
    TextDocumentDidClose,
    TextDocumentDidOpen,
    TextDocumentDidSave,
    TextDocumentPublishDiagnostics
  }

  alias GenLSP.Requests.{
    Initialize,
    Shutdown,
    TextDocumentCompletion,
    TextDocumentDefinition,
    TextDocumentHover
  }

  alias GenLSP.Structures.{
    CompletionItem,
    CompletionOptions,
    Diagnostic,
    Hover,
    InitializeResult,
    Location,
    MarkupContent,
    Position,
    PublishDiagnosticsParams,
    Range,
    ServerCapabilities,
    TextDocumentSyncOptions
  }

  @default_debounce_ms 100
  @gen_lsp_keys [:buffer, :assigns, :task_supervisor, :name, :sync_notifications]

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    {gen_lsp_opts, init_args} = Keyword.split(opts, @gen_lsp_keys)
    GenLSP.start_link(__MODULE__, init_args, gen_lsp_opts)
  end

  # -- Callbacks --

  @impl true
  def init(lsp, args) do
    languages = Keyword.get(args, :languages, [])
    debounce_ms = Keyword.get(args, :debounce_ms, @default_debounce_ms)
    db = Database.new()

    Enum.each(languages, &Lang.register(db, &1))

    {:ok,
     assign(lsp,
       db: db,
       languages: languages,
       debounce_timer: nil,
       dirty_uris: MapSet.new(),
       debounce_ms: debounce_ms,
       # LSP spec: exit code 1 if the server exits without receiving `shutdown`.
       exit_code: 1
     )}
  end

  @impl true
  def handle_request(%Initialize{params: params}, lsp) do
    %{languages: languages} = assigns(lsp)

    {:reply,
     %InitializeResult{
       capabilities: build_server_capabilities(languages),
       server_info: %{name: "Roux"}
     }, assign(lsp, root_uri: params.root_uri)}
  end

  def handle_request(%Shutdown{}, lsp) do
    %{db: db} = assigns(lsp)
    Database.shutdown(db)
    {:reply, nil, assign(lsp, exit_code: 0)}
  end

  def handle_request(%TextDocumentHover{params: params}, lsp) do
    %{db: db} = assigns(lsp)
    uri = params.text_document.uri
    position = lsp_position_to_roux(params.position)

    result =
      with {:ok, lang} <- lang_for_uri(db, uri),
           true <- function_exported?(lang, :hover_query, 0),
           content when is_binary(content) <-
             safe_dispatch(db, lang.hover_query(), {uri, position}, nil) do
        %Hover{
          contents: %MarkupContent{
            kind: MarkupKind.markdown(),
            value: content
          }
        }
      else
        _ -> nil
      end

    {:reply, result, lsp}
  end

  def handle_request(%TextDocumentCompletion{params: params}, lsp) do
    %{db: db} = assigns(lsp)
    uri = params.text_document.uri
    position = lsp_position_to_roux(params.position)

    result =
      with {:ok, lang} <- lang_for_uri(db, uri),
           true <- function_exported?(lang, :completions_query, 0),
           items when is_list(items) <-
             safe_dispatch(db, lang.completions_query(), {uri, position}, nil) do
        Enum.map(items, &to_lsp_completion_item/1)
      else
        _ -> nil
      end

    {:reply, result, lsp}
  end

  def handle_request(%TextDocumentDefinition{params: params}, lsp) do
    %{db: db} = assigns(lsp)
    uri = params.text_document.uri
    position = lsp_position_to_roux(params.position)

    result =
      with {:ok, lang} <- lang_for_uri(db, uri),
           true <- function_exported?(lang, :definition_query, 0),
           %{} = loc <- safe_dispatch(db, lang.definition_query(), {uri, position}, nil) do
        to_lsp_location(loc)
      else
        _ -> nil
      end

    {:reply, result, lsp}
  end

  def handle_request(_request, lsp) do
    {:reply, nil, lsp}
  end

  @impl true
  def handle_notification(%Initialized{}, lsp) do
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidOpen{params: params}, lsp) do
    %{db: db} = assigns(lsp)
    uri = params.text_document.uri
    text = params.text_document.text

    Input.set(db, :source_text, uri, text)
    Cancellation.cancel_dependents(db, {:input, :source_text, uri})

    {:noreply, schedule_diagnostics(lsp, uri)}
  end

  def handle_notification(%TextDocumentDidChange{params: %{content_changes: []}}, lsp) do
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidChange{params: params}, lsp) do
    %{db: db} = assigns(lsp)
    uri = params.text_document.uri
    text = List.last(params.content_changes).text

    Input.set(db, :source_text, uri, text)
    Cancellation.cancel_dependents(db, {:input, :source_text, uri})

    {:noreply, schedule_diagnostics(lsp, uri)}
  end

  def handle_notification(%TextDocumentDidClose{params: params}, lsp) do
    %{db: db} = assigns(lsp)
    uri = params.text_document.uri

    # Restore disk content when file is closed. Cancel stale tasks and
    # republish diagnostics so the editor reflects the on-disk state.
    with {:ok, path} <- uri_to_path(uri),
         {:ok, content} <- File.read(path) do
      Input.set(db, :source_text, uri, content)
      Cancellation.cancel_dependents(db, {:input, :source_text, uri})
    end

    {:noreply, schedule_diagnostics(lsp, uri)}
  end

  # Per-key durability transitions (`:low` while editing → `:medium` on save)
  # require per-key durability tracking in Input, which is not yet implemented.
  # See the "Durability limitation" section in the moduledoc.
  def handle_notification(%TextDocumentDidSave{}, lsp) do
    {:noreply, lsp}
  end

  def handle_notification(%Exit{}, lsp) do
    %{exit_code: code} = assigns(lsp)
    System.halt(code)

    {:noreply, lsp}
  end

  def handle_notification(_notification, lsp) do
    {:noreply, lsp}
  end

  @impl true
  def handle_info(:publish_diagnostics, lsp) do
    %{db: db, dirty_uris: dirty_uris} = assigns(lsp)
    lsp = assign(lsp, dirty_uris: MapSet.new(), debounce_timer: nil)

    Enum.each(dirty_uris, fn uri ->
      diagnostics = compute_diagnostics(db, uri)

      GenLSP.notify(lsp, %TextDocumentPublishDiagnostics{
        params: %PublishDiagnosticsParams{
          uri: uri,
          diagnostics: diagnostics
        }
      })
    end)

    {:noreply, lsp}
  end

  def handle_info(_message, lsp) do
    {:noreply, lsp}
  end

  # -- Public helpers --

  @doc """
  Converts a Roux 1-based position to an LSP 0-based position struct.

  Languages implementing hover or definition queries can use this to build
  LSP-compatible response ranges.
  """
  @spec roux_position_to_lsp({pos_integer(), pos_integer()}) :: Position.t()
  def roux_position_to_lsp({line, col}) do
    %Position{line: line - 1, character: col - 1}
  end

  # -- Private: position conversion --

  defp lsp_position_to_roux(%Position{line: line, character: col}) do
    {line + 1, col + 1}
  end

  # -- Private: query dispatch --

  defp safe_dispatch(db, query_name, key, default) do
    Database.dispatch_query(db, query_name, key)
  rescue
    error ->
      Logger.warning(
        "query #{inspect(query_name)} raised:\n#{Exception.format(:error, error, __STACKTRACE__)}"
      )

      default
  end

  # -- Private: diagnostics --

  defp schedule_diagnostics(lsp, uri) do
    %{debounce_timer: timer, dirty_uris: dirty_uris, debounce_ms: debounce_ms} = assigns(lsp)

    if timer, do: Process.cancel_timer(timer)

    # DidOpen/DidChange are synchronous notifications, so self() is the
    # GenLSP process. The timer message routes back to handle_info.
    new_timer = Process.send_after(self(), :publish_diagnostics, debounce_ms)

    assign(lsp,
      debounce_timer: new_timer,
      dirty_uris: MapSet.put(dirty_uris, uri)
    )
  end

  defp compute_diagnostics(db, uri) do
    with {:ok, lang} <- lang_for_uri(db, uri),
         true <- function_exported?(lang, :diagnostics_query, 0) do
      case safe_dispatch(db, lang.diagnostics_query(), uri, []) do
        diagnostics when is_list(diagnostics) ->
          Enum.map(diagnostics, &to_lsp_diagnostic/1)

        _ ->
          []
      end
    else
      _ -> []
    end
  end

  defp to_lsp_diagnostic(diag) do
    line = Map.get(diag, :line, 1)
    col = Map.get(diag, :column, 1)
    start_pos = roux_position_to_lsp({line, col})

    end_pos =
      case {Map.get(diag, :end_line), Map.get(diag, :end_column)} do
        {end_line, end_col} when is_integer(end_line) and is_integer(end_col) ->
          roux_position_to_lsp({end_line, end_col})

        _ ->
          start_pos
      end

    %Diagnostic{
      range: %Range{start: start_pos, end: end_pos},
      severity: severity_to_lsp(Map.get(diag, :severity, :error)),
      message: Map.fetch!(diag, :message)
    }
  end

  defp severity_to_lsp(:error), do: DiagnosticSeverity.error()
  defp severity_to_lsp(:warning), do: DiagnosticSeverity.warning()
  defp severity_to_lsp(:info), do: DiagnosticSeverity.information()
  defp severity_to_lsp(:hint), do: DiagnosticSeverity.hint()
  defp severity_to_lsp(_), do: DiagnosticSeverity.error()

  # -- Private: completions --

  defp to_lsp_completion_item(item) when is_binary(item) do
    %CompletionItem{label: item}
  end

  defp to_lsp_completion_item(%{label: label} = item) do
    %CompletionItem{label: label, detail: Map.get(item, :detail)}
  end

  # -- Private: definition --

  defp to_lsp_location(%{uri: uri, line: line, column: col}) do
    pos = roux_position_to_lsp({line, col})
    %Location{uri: uri, range: %Range{start: pos, end: pos}}
  end

  # -- Private: capabilities --

  defp build_server_capabilities(languages) do
    has_hover = Enum.any?(languages, &function_exported?(&1, :hover_query, 0))
    has_completion = Enum.any?(languages, &function_exported?(&1, :completions_query, 0))
    has_definition = Enum.any?(languages, &function_exported?(&1, :definition_query, 0))

    %ServerCapabilities{
      text_document_sync: %TextDocumentSyncOptions{
        open_close: true,
        change: TextDocumentSyncKind.full(),
        save: true
      },
      hover_provider: if(has_hover, do: true),
      completion_provider: if(has_completion, do: %CompletionOptions{}),
      definition_provider: if(has_definition, do: true)
    }
  end

  # -- Private: URI helpers --

  defp lang_for_uri(db, uri) do
    ext = uri_to_extension(uri)
    Lang.lang_for_extension(db, ext)
  end

  defp uri_to_extension(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path, "")
    |> Path.extname()
  end

  defp uri_to_path(uri) do
    case URI.parse(uri) do
      %URI{scheme: "file", path: path} when is_binary(path) -> {:ok, path}
      _ -> :error
    end
  end
end
