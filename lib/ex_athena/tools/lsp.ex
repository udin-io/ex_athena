defmodule ExAthena.Tools.Lsp do
  @moduledoc """
  Built-in tool that exposes Language Server Protocol queries to the model.

  Dispatches four LSP actions — `definition`, `references`, `hover`,
  `diagnostics` — by delegating to the running `ExAthena.Lsp.Client` for the
  file's language, managed by `ExAthena.Lsp.Manager`.

  Before every position-based request the tool sends `textDocument/didOpen`
  so the server has an up-to-date buffer. Repeated `didOpen` calls are
  tolerated by LSP servers — they re-sync the buffer.

  The `diagnostics` action reads push-cached diagnostics
  (`textDocument/publishDiagnostics` notifications stored by the client).
  It polls every 50 ms up to `@diagnostics_poll_ms` (default 1 500 ms,
  overridable via `config :ex_athena, :lsp_diagnostics_poll_ms, ms`).
  Servers that only support the LSP 3.17 pull protocol return an empty list —
  this is a valid result, not an error.

  ## Compact schema line

      lsp(action: string, file: string, line?: integer, character?: integer, include_declaration?: boolean) — Query LSP for definition / references / hover / diagnostics.

  ## Position params

  `line` and `character` are **0-indexed** (LSP wire format). The `read`
  tool returns 1-indexed line prefixes — subtract 1 before passing here.

  ## Return shape

  `{:ok, formatted_string, ui_payload}` on success.

  `formatted_string` per action:
    * `definition` — `path:line:col` entries joined by newline.
    * `references` — count header + one `path:line:col` per line.
    * `hover` — stripped markdown value string.
    * `diagnostics` — `<severity>: <message> at :<line>:<col>` per line,
      or `"count: 0"` when none.

  `ui_payload` — `%{kind: :lsp, payload: %{action: atom, file: path, results: list}}`.

  ## Errors

    * `{:error, :missing_action}` — `"action"` key absent.
    * `{:error, :invalid_action}` — unrecognised action string.
    * `{:error, :missing_file}` — `"file"` key absent.
    * `{:error, :missing_position}` — `line`/`character` absent for position actions.
    * `{:error, :unsupported_language}` — no LSP server for the file's extension.
    * `{:error, {:lsp_error, map}}` — server replied with a JSON-RPC error object.
    * `{:error, :timeout}` — LSP request exceeded the default 30 s timeout.
    * `{:error, {:lsp_port_exit, status}}` — server process died mid-flight.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.Lsp.{Client, Manager}
  alias ExAthena.ToolContext

  @diagnostics_poll_ms 1_500
  @diagnostics_poll_interval_ms 50

  @impl true
  def name, do: "lsp"

  @impl true
  def description,
    do: "Query the language server for definition, references, hover, or diagnostics."

  @impl true
  def parallel_safe?, do: true

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["definition", "references", "hover", "diagnostics"],
          description: "LSP action to perform"
        },
        file: %{
          type: "string",
          description: "absolute path or path relative to cwd"
        },
        line: %{
          type: "integer",
          description: "0-indexed line (required for definition/references/hover)"
        },
        character: %{
          type: "integer",
          description: "0-indexed UTF-16 column (required for definition/references/hover)"
        },
        include_declaration: %{
          type: "boolean",
          description: "for `references`: include the declaration site (default: true)"
        }
      },
      required: ["action", "file"]
    }
  end

  @impl true
  def execute(args, %ToolContext{} = ctx) do
    with {:ok, action} <- fetch_action(args),
         {:ok, abs_path} <- fetch_file(args, ctx),
         {:ok, pid} <- Manager.client_for_file(ctx.cwd, abs_path),
         :ok <- ensure_did_open(pid, abs_path),
         {:ok, raw} <- dispatch(action, pid, abs_path, args) do
      {:ok, format(action, raw, abs_path), ui(action, abs_path, raw)}
    end
  end

  # --- action fetch ---

  defp fetch_action(%{"action" => "definition"}), do: {:ok, :definition}
  defp fetch_action(%{"action" => "references"}), do: {:ok, :references}
  defp fetch_action(%{"action" => "hover"}), do: {:ok, :hover}
  defp fetch_action(%{"action" => "diagnostics"}), do: {:ok, :diagnostics}
  defp fetch_action(%{"action" => _}), do: {:error, :invalid_action}
  defp fetch_action(_), do: {:error, :missing_action}

  defp fetch_file(%{"file" => file}, ctx), do: ToolContext.resolve_path(ctx, file)
  defp fetch_file(_, _), do: {:error, :missing_file}

  # --- didOpen ---

  @doc false
  def ensure_did_open(pid, abs_path) do
    case File.read(abs_path) do
      {:ok, contents} ->
        Client.notify(pid, "textDocument/didOpen", %{
          "textDocument" => %{
            "uri" => "file://" <> abs_path,
            "languageId" => language_id(abs_path),
            "version" => 1,
            "text" => contents
          }
        })

        :ok

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  # --- dispatch ---

  defp dispatch(:definition, pid, abs_path, args) do
    with {:ok, pos} <- require_position(args) do
      pid
      |> Client.request("textDocument/definition", text_document_position(abs_path, pos))
      |> wrap_lsp_result()
    end
  end

  defp dispatch(:references, pid, abs_path, args) do
    with {:ok, pos} <- require_position(args) do
      include_declaration = Map.get(args, "include_declaration", true)

      params =
        Map.merge(text_document_position(abs_path, pos), %{
          "context" => %{"includeDeclaration" => include_declaration}
        })

      pid
      |> Client.request("textDocument/references", params)
      |> wrap_lsp_result()
    end
  end

  defp dispatch(:hover, pid, abs_path, args) do
    with {:ok, pos} <- require_position(args) do
      pid
      |> Client.request("textDocument/hover", text_document_position(abs_path, pos))
      |> wrap_lsp_result()
    end
  end

  defp dispatch(:diagnostics, pid, abs_path, _args) do
    uri = "file://" <> abs_path
    {:ok, poll_diagnostics(pid, uri)}
  end

  # Wraps a JSON-RPC error map into {:error, {:lsp_error, map}}.
  defp wrap_lsp_result({:ok, result}), do: {:ok, result}

  defp wrap_lsp_result({:error, %{"code" => _, "message" => _} = err}),
    do: {:error, {:lsp_error, err}}

  defp wrap_lsp_result({:error, reason}), do: {:error, reason}

  # --- diagnostics polling ---

  defp poll_diagnostics(pid, uri) do
    poll_ms = Application.get_env(:ex_athena, :lsp_diagnostics_poll_ms, @diagnostics_poll_ms)
    deadline = System.monotonic_time(:millisecond) + poll_ms
    do_poll(pid, uri, deadline)
  end

  defp do_poll(pid, uri, deadline) do
    case Client.diagnostics(pid, uri) do
      [] ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(@diagnostics_poll_interval_ms, remaining))
          do_poll(pid, uri, deadline)
        else
          []
        end

      diags ->
        diags
    end
  end

  # --- position helpers ---

  defp require_position(%{"line" => line, "character" => character})
       when is_integer(line) and is_integer(character) do
    {:ok, %{line: line, character: character}}
  end

  defp require_position(_), do: {:error, :missing_position}

  defp text_document_position(abs_path, %{line: line, character: character}) do
    %{
      "textDocument" => %{"uri" => "file://" <> abs_path},
      "position" => %{"line" => line, "character" => character}
    }
  end

  # --- language id ---

  defp language_id(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".py" -> "python"
      ".pyi" -> "python"
      ".rs" -> "rust"
      ".go" -> "go"
      ".ts" -> "typescript"
      ".tsx" -> "typescriptreact"
      ".js" -> "javascript"
      ".jsx" -> "javascriptreact"
      ".mjs" -> "javascript"
      ".cjs" -> "javascript"
      _ -> "plaintext"
    end
  end

  # --- formatters ---

  defp format(:definition, locations, _abs_path) when is_list(locations) do
    locations
    |> Enum.map(fn loc ->
      path = uri_to_path(loc["uri"] || "")
      start = get_in(loc, ["range", "start"]) || %{}
      "#{path}:#{start["line"] || 0}:#{start["character"] || 0}"
    end)
    |> Enum.join("\n")
  end

  defp format(:definition, _nil_or_other, _abs_path), do: ""

  defp format(:references, locations, _abs_path) when is_list(locations) do
    count = length(locations)

    lines =
      Enum.map(locations, fn loc ->
        path = uri_to_path(loc["uri"] || "")
        start = get_in(loc, ["range", "start"]) || %{}
        "  #{path}:#{start["line"] || 0}:#{start["character"] || 0}"
      end)

    "#{count} reference(s):\n" <> Enum.join(lines, "\n")
  end

  defp format(:references, _nil_or_other, _abs_path), do: "0 reference(s):"

  defp format(:hover, %{"contents" => %{"value" => value}}, _abs_path), do: value
  defp format(:hover, %{"contents" => content}, _abs_path) when is_binary(content), do: content
  defp format(:hover, _other, _abs_path), do: ""

  defp format(:diagnostics, [], _abs_path), do: "count: 0"

  defp format(:diagnostics, diags, _abs_path) when is_list(diags) do
    Enum.map_join(diags, "\n", fn d ->
      sev = severity_label(d["severity"])
      msg = d["message"] || ""
      start = get_in(d, ["range", "start"]) || %{}
      "#{sev}: #{msg} at :#{start["line"] || 0}:#{start["character"] || 0}"
    end)
  end

  defp severity_label(1), do: "error"
  defp severity_label(2), do: "warning"
  defp severity_label(3), do: "information"
  defp severity_label(4), do: "hint"
  defp severity_label(_), do: "unknown"

  # --- ui payload ---

  defp ui(action, abs_path, raw) do
    %{
      kind: :lsp,
      payload: %{
        action: action,
        file: abs_path,
        results: raw || []
      }
    }
  end

  # --- helpers ---

  defp uri_to_path("file://" <> path), do: path
  defp uri_to_path(uri), do: uri
end
