defmodule ExAthena.Chat.Tui.Runner do
  @moduledoc """
  Bridges `ExAthena.run/2` with the `ExAthena.Chat.Tui` App process.

  Owns three responsibilities:

    * `build_run_opts/2` — the keyword list passed to `ExAthena.run/2`, with
      sane defaults for local providers (Ollama, llama.cpp) and a finite-but
      generous 24h request timeout so a slow-thinking local model doesn't
      trip the default 60s timeout.
    * `select_initial_model/2` — reconciles a desired model against what's
      actually installed, returning `{:ok, _}`, `{:fallback, _}`, or
      `{:error, _}` so the App can decide how to surface the result.
    * `start/2` / `start/3` — spawn an unsupervised `Task` that runs the
      agent loop, sending `{:athena_event, _}` for each loop event and a
      terminal `{:athena_done, _}` or `{:athena_error, _}` when the run
      finishes. The task body is wrapped in `try/rescue/catch` so failures
      always reach the App (per the CLAUDE.md "Task.start silently swallows
      crashes" rule).
  """

  alias ExAthena.Chat.{Permission, Session}
  alias ExAthena.Config

  @run_timeout_ms 24 * 60 * 60 * 1000

  @spec start(Session.t(), pid()) :: pid()
  def start(%Session{} = session, target_pid), do: start(session, target_pid, [])

  @spec start(Session.t(), pid(), keyword()) :: pid()
  def start(%Session{} = session, target_pid, extra_opts) when is_pid(target_pid) do
    callback = build_callback(target_pid)
    opts = session |> build_run_opts(callback, target_pid) |> Keyword.merge(extra_opts)

    {:ok, pid} =
      Task.start(fn ->
        try do
          case ExAthena.run(nil, opts) do
            {:ok, result} -> send(target_pid, {:athena_done, result})
            {:error, reason} -> send(target_pid, {:athena_error, reason})
          end
        rescue
          e -> send(target_pid, {:athena_error, {:exception, e, __STACKTRACE__}})
        catch
          kind, reason -> send(target_pid, {:athena_error, {kind, reason}})
        end
      end)

    pid
  end

  @spec build_callback(pid()) :: (term() -> :ok)
  def build_callback(target_pid) when is_pid(target_pid) do
    fn event ->
      send(target_pid, {:athena_event, event})
      :ok
    end
  end

  @doc """
  The run options for `session`. With `ask_host:` (the TUI App's pid), the
  session's permission level asks its approvals there, and `ask_user`
  questions reach it too; without one, nothing can be asked, so the level's
  approvals deny.
  """
  @spec build_run_opts(Session.t(), (term() -> term()), pid() | nil) :: keyword()
  def build_run_opts(%Session{} = session, callback, ask_host \\ nil)
      when is_function(callback, 1) do
    base = [
      provider: session.provider,
      model: session.model,
      tools: session.tools,
      messages: session.messages,
      on_event: callback,
      timeout_ms: @run_timeout_ms,
      # The chat's id, so the file history every edit writes lines up with the
      # saved chat a rewind reads (ExAthena.Chats.rewind/3).
      session_id: session.chat_id
    ]

    base
    |> put_permission(session.permission, ask_host)
    |> maybe_put_cwd(session.cwd)
    |> maybe_put_confine(session.cwd)
    |> maybe_put_resume(session.provider_session_id)
    |> apply_default_base_url(session.provider)
    |> apply_provider_spec_extra_headers(session.provider)
  end

  defp put_permission(opts, level, host) do
    ask = fn question, options, kind ->
      id = "approval-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

      if is_pid(host) do
        case ExAthena.Tools.AskUser.ask(host, id, question, options, %{kind: kind}) do
          {:ok, answer} -> answer
          {:error, :host_down} -> :gone
        end
      else
        :gone
      end
    end

    {_ref, permission_opts} = Keyword.pop(Permission.run_opts(level, ask), :level_ref)

    opts
    |> Keyword.merge(permission_opts)
    |> then(fn o -> if is_pid(host), do: Keyword.put(o, :assigns, %{ask_user: host}), else: o end)
  end

  # Confine to the session's working directory by default (override with
  # EX_ATHENA_CONFINE=0). Only when a cwd is set — there's no root otherwise.
  defp maybe_put_confine(opts, cwd) when is_binary(cwd) and cwd != "",
    do: Keyword.put(opts, :confine, ExAthena.confine_default?())

  defp maybe_put_confine(opts, _), do: opts

  defp maybe_put_cwd(opts, cwd) when is_binary(cwd) and cwd != "",
    do: Keyword.put(opts, :cwd, cwd)

  defp maybe_put_cwd(opts, _), do: opts

  # Continue the provider-side conversation (e.g. a Claude Code CLI session)
  # captured from the previous Result. Providers without server-side session
  # state never populate it, so this stays provider-agnostic.
  defp maybe_put_resume(opts, session_id) when is_binary(session_id) and session_id != "",
    do: Keyword.put(opts, :resume, session_id)

  defp maybe_put_resume(opts, _), do: opts

  @spec select_initial_model(String.t(), {:ok, [String.t()]} | {:error, term()}) ::
          {:ok, String.t()}
          | {:fallback, String.t()}
          | {:error,
             :no_models
             | :ollama_unreachable
             | :llamacpp_unreachable
             | :exo_unreachable
             | term()}
  def select_initial_model(_desired, {:ok, []}), do: {:error, :no_models}

  def select_initial_model(desired, {:ok, [_ | _] = installed}) do
    if desired in installed, do: {:ok, desired}, else: {:fallback, hd(installed)}
  end

  def select_initial_model(_desired, {:error, reason}), do: {:error, reason}

  # The stock URLs live in `Config.default_base_url/1` (shared with the
  # listing path), and it is nil for everything that isn't a local daemon.
  # Only local daemons get a default filled in, so a zero-config TUI run
  # still reaches ollama / llama.cpp / exo on its stock port. Every other
  # provider is left without a `:base_url` for the adapter and app config to
  # resolve — the TUI used to route unknown providers to the Ollama key,
  # which injected `http://localhost:11434` into cloud runs (#192).
  #
  # An explicitly configured URL always wins: it is omitted here and picked
  # up downstream by `Config.provider_opts/3`.
  defp apply_default_base_url(opts, provider) do
    case Config.default_base_url(provider) do
      nil ->
        opts

      default ->
        case Application.get_env(:ex_athena, provider, [])[:base_url] do
          nil -> Keyword.put(opts, :base_url, default)
          _configured -> opts
        end
    end
  end

  defp apply_provider_spec_extra_headers(opts, provider) when is_atom(provider) do
    case lookup_registry_spec(provider) do
      {:ok, %{extra_headers: headers}} when headers != %{} ->
        existing = Keyword.get(opts, :extra_headers, %{})
        Keyword.put(opts, :extra_headers, Map.merge(existing, headers))

      _ ->
        opts
    end
  end

  defp lookup_registry_spec(provider) when is_atom(provider) do
    case Process.whereis(ExAthena.ProviderRegistry) do
      nil -> :error
      _pid -> ExAthena.ProviderRegistry.lookup(provider)
    end
  end
end
