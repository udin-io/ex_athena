defmodule ExAthena.Lsp.ImplicitDiagnostics do
  @moduledoc """
  PostToolUse hook that automatically fetches LSP diagnostics after Edit/Write
  tool calls and injects any errors or warnings into the next turn's tool-result.

  When the model edits a file, the hook:

    1. Resolves the file path from the tool call's `arguments["path"]`.
    2. Looks up (or spawns) the language server for the file's extension.
    3. Waits up to `:lsp_implicit_diagnostics_start_timeout_ms` (default
       5000 ms) for the server to answer its `initialize` handshake. A server
       just launched spends this time booting; one already running answers at
       once.
    4. Sends `textDocument/didOpen` with the current file contents.
    5. Polls `publishDiagnostics` push-notifications for up to
       `:lsp_implicit_diagnostics_timeout_ms` (default 1500 ms). The window
       opens after the handshake, so a slow boot does not eat it.
    6. Filters to `:lsp_implicit_diagnostics_severities` (default `[:error, :warning]`).
    7. Returns `{:augment, text}` with a `[lsp diagnostics]` block, or
       `:ok` if there is nothing to report.

  All failure paths (LSP disabled, unsupported file type, server crash, timeout)
  collapse to `:ok`. The hook runs inside the agent loop, so every wait in it
  is bounded by a setting: it blocks for at most the start timeout plus the
  diagnostics window (5 s and 1.5 s by default), plus up to 5 s for each of the
  Manager lookup and the last diagnostics poll when those processes are busy.
  A large setting makes a long wait; keep both in seconds, not minutes.

  ## Configuration keys

    * `:lsp_implicit_diagnostics_enabled` — boolean, default `true`
    * `:lsp_implicit_diagnostics_start_timeout_ms` — how long to wait for a
      server to finish starting, in ms, default `5000`
    * `:lsp_implicit_diagnostics_timeout_ms` — poll deadline in ms, default `1500`
    * `:lsp_implicit_diagnostics_severities` — list of `:error | :warning |
      :information | :hint`, default `[:error, :warning]`
  """

  require Logger

  alias ExAthena.Lsp.{Client, Manager, ServerRegistry}
  alias ExAthena.Tools.Lsp, as: LspTool

  @default_timeout_ms 1_500
  @default_start_timeout_ms 5_000
  # The largest timeout GenServer.call/3 and Process.send_after/3 accept.
  @max_timeout_ms 4_294_967_295
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
    with true <- enabled?() || log_skip(:disabled),
         {:ok, abs_path} <- file_from_payload(payload) |> log_step(:no_path),
         :ok <- has_language?(abs_path) |> log_step(:unsupported_language, abs_path),
         {:ok, pid} <- client_for_file(payload, abs_path) |> log_step(:no_client, abs_path),
         :ok <-
           Client.await_initialized(pid, start_timeout_ms())
           |> log_step(:server_not_started, abs_path),
         :ok <- LspTool.ensure_did_open(pid, abs_path) |> log_step(:did_open_failed, abs_path),
         diags when diags != [] <-
           await_diagnostics(pid, abs_path) |> log_no_diags(abs_path),
         filtered when filtered != [] <-
           filter_severities(diags) |> log_filtered_out(abs_path) do
      {:augment, format(filtered, abs_path, Map.get(payload, :cwd, ""))}
    else
      _ -> :ok
    end
  end

  # --- failure-mode logging helpers ---
  # Each helper passes through its argument unchanged so the `with` chain is
  # unaffected; a Logger.debug fires on the failure paths so operators can
  # diagnose why diagnostics never appeared.

  defp log_skip(:disabled) do
    Logger.debug("[ExAthena.Lsp.ImplicitDiagnostics] skipped: lsp disabled")
    false
  end

  defp log_step({:ok, _} = ok, _reason), do: ok

  defp log_step(other, reason) do
    Logger.debug("[ExAthena.Lsp.ImplicitDiagnostics] skipped: #{reason} (#{inspect(other)})")
    other
  end

  defp log_step({:ok, _} = ok, _reason, _ctx), do: ok
  defp log_step(:ok, _reason, _ctx), do: :ok

  defp log_step(other, reason, ctx) do
    Logger.debug(
      "[ExAthena.Lsp.ImplicitDiagnostics] skipped: #{reason} for #{ctx} (#{inspect(other)})"
    )

    other
  end

  defp log_no_diags([], abs_path) do
    Logger.debug(
      "[ExAthena.Lsp.ImplicitDiagnostics] no diagnostics within timeout for #{abs_path}"
    )

    []
  end

  defp log_no_diags(diags, _abs_path), do: diags

  defp log_filtered_out([], abs_path) do
    Logger.debug(
      "[ExAthena.Lsp.ImplicitDiagnostics] all diagnostics filtered by severity for #{abs_path}"
    )

    []
  end

  defp log_filtered_out(diags, _abs_path), do: diags

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

  defp start_timeout_ms,
    do: ms_setting(:lsp_implicit_diagnostics_start_timeout_ms, @default_start_timeout_ms)

  # A timeout that is not a whole number of milliseconds within the VM's timer
  # limit would raise inside the hook, and a raise there halts the agent run.
  # Use the default instead, and warn once per bad value, not once per edit.
  defp ms_setting(key, default) do
    case Application.get_env(:ex_athena, key, default) do
      ms when is_integer(ms) and ms >= 0 and ms <= @max_timeout_ms ->
        ms

      other ->
        warn_once(key, other, default)
        default
    end
  end

  defp warn_once(key, value, default, wanted \\ nil) do
    marker = {__MODULE__, :bad_setting, key, value}

    unless :persistent_term.get(marker, false) do
      :persistent_term.put(marker, true)
      wanted = wanted || "a whole number of milliseconds from 0 to #{@max_timeout_ms}"

      Logger.warning(
        "[ExAthena.Lsp.ImplicitDiagnostics] #{key} must be #{wanted}, " <>
          "got #{inspect(value)}; using #{inspect(default)}"
      )
    end
  end

  defp await_diagnostics(pid, abs_path) do
    timeout_ms = ms_setting(:lsp_implicit_diagnostics_timeout_ms, @default_timeout_ms)

    uri = "file://" <> abs_path
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(pid, uri, deadline)
  end

  defp do_poll(pid, uri, deadline) do
    case current_diagnostics(pid, uri) do
      :client_down ->
        []

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

  # A server that dies mid-window must not crash the agent loop.
  defp current_diagnostics(pid, uri) do
    Client.diagnostics(pid, uri)
  catch
    :exit, _ -> :client_down
  end

  # The server writes these, so read them defensively: skip entries that are
  # not maps, and treat a payload that is not a list as no diagnostics.
  defp filter_severities(diags) when is_list(diags) do
    allowed = severities_setting()

    Enum.filter(diags, fn d ->
      is_map(d) and Map.get(@severity_atoms, d["severity"]) in allowed
    end)
  end

  defp filter_severities(_diags), do: []

  defp severities_setting do
    case Application.get_env(
           :ex_athena,
           :lsp_implicit_diagnostics_severities,
           @default_severities
         ) do
      list when is_list(list) ->
        list

      other ->
        warn_once(:lsp_implicit_diagnostics_severities, other, @default_severities, "a list")
        @default_severities
    end
  end

  defp format(diags, abs_path, cwd) do
    rel = if cwd != "", do: Path.relative_to(abs_path, cwd), else: abs_path

    lines =
      Enum.map(diags, fn d ->
        sev = Map.get(@severity_atoms, d["severity"], :unknown)
        msg = if is_binary(d["message"]), do: d["message"], else: ""
        start = position(d["range"])
        "#{sev}: #{msg} at #{rel}:#{start.line + 1}:#{start.col + 1}"
      end)

    "[lsp diagnostics]\n" <> Enum.join(lines, "\n")
  end

  defp position(%{"start" => %{} = start}),
    do: %{line: non_neg(start["line"]), col: non_neg(start["character"])}

  defp position(_range), do: %{line: 0, col: 0}

  defp non_neg(n) when is_integer(n) and n >= 0, do: n
  defp non_neg(_), do: 0

  defp count_from({:augment, text}) do
    text |> String.split("\n") |> Enum.count(&(&1 =~ ~r/^(error|warning|information|hint):/))
  end

  defp count_from(:ok), do: 0

  defp had_errors?({:augment, text}), do: text =~ ~r/^error:/m
  defp had_errors?(:ok), do: false
end
