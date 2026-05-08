defmodule ExAthena.Lsp.ImplicitDiagnostics do
  @moduledoc """
  PostToolUse hook that automatically fetches LSP diagnostics after Edit/Write
  tool calls and injects any errors or warnings into the next turn's tool-result.

  When the model edits a file, the hook:

    1. Resolves the file path from the tool call's `arguments["path"]`.
    2. Looks up (or spawns) the language server for the file's extension.
    3. Sends `textDocument/didOpen` with the current file contents.
    4. Polls `publishDiagnostics` push-notifications for up to
       `:lsp_implicit_diagnostics_timeout_ms` (default 1500 ms).
    5. Filters to `:lsp_implicit_diagnostics_severities` (default `[:error, :warning]`).
    6. Returns `{:augment, text}` with a `[lsp diagnostics]` block, or
       `:ok` if there is nothing to report.

  All failure paths (LSP disabled, unsupported file type, server crash, timeout)
  collapse to `:ok` — the hook must never stall the agent loop.

  ## Configuration keys

    * `:lsp_implicit_diagnostics_enabled` — boolean, default `true`
    * `:lsp_implicit_diagnostics_timeout_ms` — poll deadline in ms, default `1500`
    * `:lsp_implicit_diagnostics_severities` — list of `:error | :warning |
      :information | :hint`, default `[:error, :warning]`
  """

  alias ExAthena.Lsp.{Client, Manager, ServerRegistry}
  alias ExAthena.Tools.Lsp, as: LspTool

  @default_timeout_ms 1_500
  @default_severities [:error, :warning]
  @poll_interval_ms 50

  @severity_atoms %{1 => :error, 2 => :warning, 3 => :information, 4 => :hint}

  @doc """
  PostToolUse hook function. Receives the payload map and tool_use_id.

  Returns `{:augment, text}` when LSP diagnostics are available, otherwise `:ok`.
  Emits `[:ex_athena, :lsp, :implicit_diagnostics, :start | :stop]` telemetry events.
  """
  @spec post_tool_use_hook(map(), String.t() | nil) :: :ok | {:augment, String.t()}
  def post_tool_use_hook(payload, _tool_use_id) do
    tool_name = Map.get(payload, :tool_name, "unknown")
    meta = %{tool_name: tool_name}
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:ex_athena, :lsp, :implicit_diagnostics, :start],
      %{system_time: System.system_time()},
      meta
    )

    result = run(payload)

    duration_native = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)

    :telemetry.execute(
      [:ex_athena, :lsp, :implicit_diagnostics, :stop],
      %{
        duration_ms: duration_ms,
        duration_native: duration_native,
        count: count_from(result),
        had_errors: had_errors?(result)
      },
      meta
    )

    result
  end

  @doc "Default hook entry to merge into Loop.start's hooks map."
  @spec default_hooks_entry() :: map()
  def default_hooks_entry do
    %{matcher: "^(Edit|Write)$", hooks: [&__MODULE__.post_tool_use_hook/2]}
  end

  @doc """
  Merge the default implicit-diagnostics hook into a user-supplied hooks map.

  When `:lsp_implicit_diagnostics_enabled` is false (the default in tests),
  returns `hooks` unchanged. Otherwise prepends the built-in entry to the
  `:PostToolUse` list so user-supplied hooks still run after it.
  """
  @spec maybe_merge(ExAthena.Hooks.t()) :: ExAthena.Hooks.t()
  def maybe_merge(hooks) do
    if enabled?() do
      existing = Map.get(hooks, :PostToolUse, [])
      Map.put(hooks, :PostToolUse, [default_hooks_entry() | existing])
    else
      hooks
    end
  end

  # --- private ---

  defp run(payload) do
    with true <- enabled?(),
         {:ok, abs_path} <- file_from_payload(payload),
         :ok <- has_language?(abs_path),
         {:ok, pid} <- client_for_file(payload, abs_path),
         :ok <- LspTool.ensure_did_open(pid, abs_path),
         diags when diags != [] <- await_diagnostics(pid, abs_path),
         filtered when filtered != [] <- filter_severities(diags) do
      {:augment, format(filtered, abs_path, Map.get(payload, :cwd, ""))}
    else
      _ -> :ok
    end
  end

  defp enabled? do
    Application.get_env(:ex_athena, :lsp_implicit_diagnostics_enabled, true) == true
  end

  defp file_from_payload(%{arguments: args, cwd: cwd}) when is_map(args) do
    case Map.get(args, "path") do
      nil ->
        :skip

      rel_or_abs ->
        abs =
          if Path.type(rel_or_abs) == :absolute,
            do: rel_or_abs,
            else: Path.expand(rel_or_abs, cwd || ".")

        {:ok, abs}
    end
  end

  defp file_from_payload(_), do: :skip

  defp has_language?(abs_path) do
    case ServerRegistry.language_for_path(abs_path) do
      nil -> :skip
      _lang -> :ok
    end
  end

  defp client_for_file(%{cwd: cwd}, abs_path) when is_binary(cwd) do
    try do
      Manager.client_for_file(cwd, abs_path)
    catch
      :exit, _ -> {:error, :manager_unavailable}
    end
  end

  defp client_for_file(_, _), do: {:error, :no_cwd}

  defp await_diagnostics(pid, abs_path) do
    timeout_ms =
      Application.get_env(
        :ex_athena,
        :lsp_implicit_diagnostics_timeout_ms,
        @default_timeout_ms
      )

    uri = "file://" <> abs_path
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(pid, uri, deadline)
  end

  defp do_poll(pid, uri, deadline) do
    case Client.diagnostics(pid, uri) do
      [] ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(@poll_interval_ms, remaining))
          do_poll(pid, uri, deadline)
        else
          []
        end

      diags ->
        diags
    end
  end

  defp filter_severities(diags) do
    allowed =
      Application.get_env(
        :ex_athena,
        :lsp_implicit_diagnostics_severities,
        @default_severities
      )

    Enum.filter(diags, fn d ->
      atom = Map.get(@severity_atoms, d["severity"])
      atom in allowed
    end)
  end

  defp format(diags, abs_path, cwd) do
    rel = if cwd != "", do: Path.relative_to(abs_path, cwd), else: abs_path

    lines =
      Enum.map(diags, fn d ->
        sev = Map.get(@severity_atoms, d["severity"], :unknown)
        msg = d["message"] || ""
        start = get_in(d, ["range", "start"]) || %{}
        line = (start["line"] || 0) + 1
        col = (start["character"] || 0) + 1
        "#{sev}: #{msg} at #{rel}:#{line}:#{col}"
      end)

    "[lsp diagnostics]\n" <> Enum.join(lines, "\n")
  end

  defp count_from({:augment, text}) do
    text |> String.split("\n") |> Enum.count(&(&1 =~ ~r/^(error|warning|information|hint):/))
  end

  defp count_from(:ok), do: 0

  defp had_errors?({:augment, text}), do: text =~ "error:"
  defp had_errors?(:ok), do: false
end
