defmodule Roux.Lang.LSPTest do
  use ExUnit.Case
  use ExUnitProperties

  import GenLSP.Test

  alias Roux.Lang.LSP

  # Generous timeout for all LSP assertions — under full-suite concurrent load,
  # GenLSP TCP setup and async dispatch can take longer than the 100ms default.
  @lsp_timeout 5000

  setup do
    server = server(LSP, languages: [Roux.Test.HoverLang], debounce_ms: 0)
    client = client(server)

    # ExUnit automatically cleans up start_supervised! processes.
    %{server: server, client: client}
  end

  defp initialize(client, id \\ 1) do
    request(client, %{
      method: "initialize",
      id: id,
      jsonrpc: "2.0",
      params: %{capabilities: %{}, rootUri: "file:///tmp/test_project"}
    })

    assert_result(^id, %{"capabilities" => _}, @lsp_timeout)

    notify(client, %{method: "initialized", jsonrpc: "2.0", params: %{}})
  end

  describe "initialize" do
    test "returns capabilities with hover and text document sync", %{client: client} do
      id = 1

      request(client, %{
        method: "initialize",
        id: id,
        jsonrpc: "2.0",
        params: %{capabilities: %{}, rootUri: "file:///tmp/test_project"}
      })

      assert_result(
        ^id,
        %{
          "capabilities" => %{
            "textDocumentSync" => %{
              "openClose" => true,
              "change" => 1,
              "save" => true
            },
            "hoverProvider" => true,
            "completionProvider" => %{},
            "definitionProvider" => true
          },
          "serverInfo" => %{"name" => "Roux"}
        },
        @lsp_timeout
      )
    end
  end

  describe "diagnostics" do
    test "didOpen with error triggers diagnostic push", %{client: client} do
      initialize(client)

      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: "file:///tmp/test.hover",
            languageId: "hover",
            version: 1,
            text: "this has an error in it"
          }
        }
      })

      assert_notification(
        "textDocument/publishDiagnostics",
        %{
          "uri" => "file:///tmp/test.hover",
          "diagnostics" => [
            %{
              "message" => "found error in source",
              "severity" => 1,
              "range" => %{
                "start" => %{"line" => 0, "character" => 0},
                "end" => %{"line" => 0, "character" => 0}
              }
            }
          ]
        },
        @lsp_timeout
      )
    end

    test "didOpen with clean file produces empty diagnostics", %{client: client} do
      initialize(client)

      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: "file:///tmp/clean.hover",
            languageId: "hover",
            version: 1,
            text: "clean source"
          }
        }
      })

      assert_notification(
        "textDocument/publishDiagnostics",
        %{
          "uri" => "file:///tmp/clean.hover",
          "diagnostics" => []
        },
        @lsp_timeout
      )
    end

    @tag :tmp_dir
    test "didClose restores disk content", %{client: client, tmp_dir: tmp_dir} do
      initialize(client)

      # Write a clean file to disk.
      path = Path.join(tmp_dir, "closable.hover")
      File.write!(path, "disk content")
      uri = "file://#{path}"

      # Open with content containing "error" — should produce diagnostics.
      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: uri,
            languageId: "hover",
            version: 1,
            text: "editor has an error"
          }
        }
      })

      assert_notification(
        "textDocument/publishDiagnostics",
        %{"uri" => ^uri, "diagnostics" => [%{"message" => "found error in source"}]},
        @lsp_timeout
      )

      # Close the file — server should restore disk content.
      notify(client, %{
        method: "textDocument/didClose",
        jsonrpc: "2.0",
        params: %{textDocument: %{uri: uri}}
      })

      # Verify by hovering — the hover query reads source_text, which should
      # now be the clean disk content ("disk content"), not the editor content.
      id = 2

      request(client, %{
        method: "textDocument/hover",
        id: id,
        jsonrpc: "2.0",
        params: %{
          textDocument: %{uri: uri},
          position: %{line: 0, character: 0}
        }
      })

      assert_result(
        ^id,
        %{
          "contents" => %{
            "kind" => "markdown",
            "value" => "Hover info for: disk content at 1:1"
          }
        },
        @lsp_timeout
      )
    end

    test "didChange updates diagnostics", %{client: client} do
      initialize(client)

      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: "file:///tmp/changing.hover",
            languageId: "hover",
            version: 1,
            text: "clean source"
          }
        }
      })

      assert_notification(
        "textDocument/publishDiagnostics",
        %{
          "uri" => "file:///tmp/changing.hover",
          "diagnostics" => []
        },
        @lsp_timeout
      )

      notify(client, %{
        method: "textDocument/didChange",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{uri: "file:///tmp/changing.hover", version: 2},
          contentChanges: [%{text: "now has an error"}]
        }
      })

      assert_notification(
        "textDocument/publishDiagnostics",
        %{
          "uri" => "file:///tmp/changing.hover",
          "diagnostics" => [%{"message" => "found error in source"}]
        },
        @lsp_timeout
      )
    end
  end

  describe "hover" do
    test "returns hover content for registered language", %{client: client} do
      initialize(client)

      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: "file:///tmp/hover.hover",
            languageId: "hover",
            version: 1,
            text: "hello world"
          }
        }
      })

      # Wait for diagnostics to ensure file is processed.
      assert_notification("textDocument/publishDiagnostics", _, @lsp_timeout)

      id = 2

      request(client, %{
        method: "textDocument/hover",
        id: id,
        jsonrpc: "2.0",
        params: %{
          textDocument: %{uri: "file:///tmp/hover.hover"},
          position: %{line: 0, character: 0}
        }
      })

      assert_result(
        ^id,
        %{
          "contents" => %{
            "kind" => "markdown",
            "value" => "Hover info for: hello world at 1:1"
          }
        },
        @lsp_timeout
      )
    end

    test "returns null for unknown extension", %{client: client} do
      initialize(client)

      id = 2

      request(client, %{
        method: "textDocument/hover",
        id: id,
        jsonrpc: "2.0",
        params: %{
          textDocument: %{uri: "file:///tmp/unknown.xyz"},
          position: %{line: 0, character: 0}
        }
      })

      assert_result(^id, nil, @lsp_timeout)
    end
  end

  describe "completion" do
    test "returns completion items for registered language", %{client: client} do
      initialize(client)

      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: "file:///tmp/complete.hover",
            languageId: "hover",
            version: 1,
            text: "alpha beta"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", _, @lsp_timeout)

      id = 2

      request(client, %{
        method: "textDocument/completion",
        id: id,
        jsonrpc: "2.0",
        params: %{
          textDocument: %{uri: "file:///tmp/complete.hover"},
          position: %{line: 0, character: 0}
        }
      })

      assert_result(
        ^id,
        [
          %{"label" => "alpha", "detail" => "word from source"},
          %{"label" => "beta", "detail" => "word from source"}
        ],
        @lsp_timeout
      )
    end
  end

  describe "definition" do
    test "returns location for registered language", %{client: client} do
      initialize(client)

      uri = "file:///tmp/defn.hover"

      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: uri,
            languageId: "hover",
            version: 1,
            text: "some source"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", _, @lsp_timeout)

      id = 2

      request(client, %{
        method: "textDocument/definition",
        id: id,
        jsonrpc: "2.0",
        params: %{
          textDocument: %{uri: uri},
          position: %{line: 0, character: 0}
        }
      })

      assert_result(
        ^id,
        %{
          "uri" => ^uri,
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 0}
          }
        },
        @lsp_timeout
      )
    end

    test "returns null for unknown extension", %{client: client} do
      initialize(client)

      id = 2

      request(client, %{
        method: "textDocument/definition",
        id: id,
        jsonrpc: "2.0",
        params: %{
          textDocument: %{uri: "file:///tmp/unknown.xyz"},
          position: %{line: 0, character: 0}
        }
      })

      assert_result(^id, nil, @lsp_timeout)
    end
  end

  describe "rapid edits" do
    test "rapid edits produce diagnostics reflecting final state", %{client: client} do
      initialize(client)

      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: "file:///tmp/rapid.hover",
            languageId: "hover",
            version: 1,
            text: "initial"
          }
        }
      })

      # Drain the initial diagnostics.
      assert_notification("textDocument/publishDiagnostics", _, @lsp_timeout)

      # Fire several rapid edits — intermediate states should be superseded.
      for {text, version} <- [{"edit1", 2}, {"edit2", 3}, {"final error state", 4}] do
        notify(client, %{
          method: "textDocument/didChange",
          jsonrpc: "2.0",
          params: %{
            textDocument: %{uri: "file:///tmp/rapid.hover", version: version},
            contentChanges: [%{text: text}]
          }
        })
      end

      # The last diagnostic notification must reflect the final state.
      # Drain any intermediate notifications and verify the last one has the error.
      final_diagnostics = drain_diagnostics("file:///tmp/rapid.hover")
      assert [%{"message" => "found error in source"}] = final_diagnostics
    end
  end

  # Drains all publishDiagnostics notifications for a URI, returning the last
  # diagnostics list. Waits generously for the first notification, then uses
  # a short timeout to collect any remaining batched notifications.
  defp drain_diagnostics(uri) do
    receive do
      %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/publishDiagnostics",
        "params" => %{"uri" => ^uri, "diagnostics" => diagnostics}
      } ->
        drain_remaining(uri, diagnostics)
    after
      @lsp_timeout ->
        flunk("expected at least one publishDiagnostics for #{uri}")
    end
  end

  defp drain_remaining(uri, last) do
    receive do
      %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/publishDiagnostics",
        "params" => %{"uri" => ^uri, "diagnostics" => diagnostics}
      } ->
        drain_remaining(uri, diagnostics)
    after
      200 -> last
    end
  end

  describe "position conversion" do
    test "roux_position_to_lsp converts 1-based to 0-based" do
      assert %GenLSP.Structures.Position{line: 0, character: 0} =
               LSP.roux_position_to_lsp({1, 1})

      assert %GenLSP.Structures.Position{line: 4, character: 9} =
               LSP.roux_position_to_lsp({5, 10})
    end

    property "roux_position_to_lsp subtracts 1 from both components" do
      check all(
              line <- StreamData.positive_integer(),
              col <- StreamData.positive_integer()
            ) do
        %GenLSP.Structures.Position{line: lsp_line, character: lsp_col} =
          LSP.roux_position_to_lsp({line, col})

        assert lsp_line == line - 1
        assert lsp_col == col - 1
      end
    end
  end

  describe "diagnostic severity" do
    test "warning severity maps to LSP severity 2", %{client: client} do
      initialize(client)

      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: "file:///tmp/warn.hover",
            languageId: "hover",
            version: 1,
            text: "this has a warning"
          }
        }
      })

      assert_notification(
        "textDocument/publishDiagnostics",
        %{
          "uri" => "file:///tmp/warn.hover",
          "diagnostics" => [
            %{
              "message" => "found warning in source",
              "severity" => 2
            }
          ]
        },
        @lsp_timeout
      )
    end
  end

  describe "multi-file diagnostics" do
    test "two files get independent diagnostics", %{client: client} do
      initialize(client)

      # Open a clean file.
      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: "file:///tmp/multi_clean.hover",
            languageId: "hover",
            version: 1,
            text: "clean"
          }
        }
      })

      # Open a file with an error.
      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: "file:///tmp/multi_error.hover",
            languageId: "hover",
            version: 1,
            text: "has an error"
          }
        }
      })

      # Collect diagnostics for both URIs. Debounce is 0 so they may arrive
      # in one batch or two — collect until we have both.
      diagnostics =
        collect_diagnostics_for_uris([
          "file:///tmp/multi_clean.hover",
          "file:///tmp/multi_error.hover"
        ])

      assert diagnostics["file:///tmp/multi_clean.hover"] == []

      assert [%{"message" => "found error in source"}] =
               diagnostics["file:///tmp/multi_error.hover"]
    end
  end

  describe "didClose clears diagnostics" do
    @tag :tmp_dir
    test "closing a file with errors republishes clean diagnostics", %{
      client: client,
      tmp_dir: tmp_dir
    } do
      initialize(client)

      # Write a clean file to disk.
      path = Path.join(tmp_dir, "clearable.hover")
      File.write!(path, "clean on disk")
      uri = "file://#{path}"

      # Open with error content.
      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: uri,
            languageId: "hover",
            version: 1,
            text: "editor has an error"
          }
        }
      })

      assert_notification(
        "textDocument/publishDiagnostics",
        %{"uri" => ^uri, "diagnostics" => [%{"message" => "found error in source"}]},
        @lsp_timeout
      )

      # Close the file — should republish diagnostics based on disk content.
      notify(client, %{
        method: "textDocument/didClose",
        jsonrpc: "2.0",
        params: %{textDocument: %{uri: uri}}
      })

      assert_notification(
        "textDocument/publishDiagnostics",
        %{"uri" => ^uri, "diagnostics" => []},
        @lsp_timeout
      )
    end
  end

  describe "error resilience" do
    @describetag :capture_log

    setup do
      # Use a separate server with FailingLang to test error paths.
      # Unique IDs to avoid conflicting with the module-level setup.
      server =
        server(LSP,
          languages: [Roux.Test.HoverLang, Roux.Test.FailingLang],
          debounce_ms: 0,
          buffer_id: :fail_buffer,
          assigns_id: :fail_assigns,
          task_supervisor_id: :fail_task_supervisor,
          lsp_id: :fail_lsp
        )

      client = client(server)
      %{server: server, client: client}
    end

    test "raising query returns null instead of crashing server", %{client: client} do
      initialize(client)

      # Open a .fail file so FailingLang's hover query is reachable.
      notify(client, %{
        method: "textDocument/didOpen",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{
            uri: "file:///tmp/boom.fail",
            languageId: "fail",
            version: 1,
            text: "boom"
          }
        }
      })

      id = 2

      request(client, %{
        method: "textDocument/hover",
        id: id,
        jsonrpc: "2.0",
        params: %{
          textDocument: %{uri: "file:///tmp/boom.fail"},
          position: %{line: 0, character: 0}
        }
      })

      # The raising hover query should return null, not crash the server.
      assert_result(^id, nil, @lsp_timeout)

      # Verify the server is still alive by making another request.
      id2 = 3

      request(client, %{
        method: "textDocument/hover",
        id: id2,
        jsonrpc: "2.0",
        params: %{
          textDocument: %{uri: "file:///tmp/unknown.xyz"},
          position: %{line: 0, character: 0}
        }
      })

      assert_result(^id2, nil, @lsp_timeout)
    end
  end

  # Collects publishDiagnostics notifications until all expected URIs are seen.
  defp collect_diagnostics_for_uris(uris) do
    remaining = MapSet.new(uris)
    do_collect_diagnostics(remaining, %{})
  end

  defp do_collect_diagnostics(remaining, acc) do
    if MapSet.size(remaining) == 0 do
      acc
    else
      receive do
        %{
          "jsonrpc" => "2.0",
          "method" => "textDocument/publishDiagnostics",
          "params" => %{"uri" => uri, "diagnostics" => diagnostics}
        } ->
          acc = Map.put(acc, uri, diagnostics)
          remaining = MapSet.delete(remaining, uri)
          do_collect_diagnostics(remaining, acc)
      after
        @lsp_timeout ->
          flunk(
            "timed out waiting for diagnostics, still missing: #{inspect(MapSet.to_list(remaining))}"
          )
      end
    end
  end
end
