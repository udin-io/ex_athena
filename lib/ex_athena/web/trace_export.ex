defmodule ExAthena.Web.TraceExport do
  @moduledoc """
  A session's trace as one HTML file that opens in any browser with no
  server (issue 353): the Trace tab's drawing, every turn's details, the CSS
  and a small script that opens a mark's details on click. The Trace tab's
  Save button and `mix athena.trace` both write it.

  A session can hold code and secrets, so the file leaves things out before
  it renders anything:

    * file contents: what a read returned, and the text a write or an edit
      sent, are replaced with a note;
    * output past the first 2,000 characters, as the tab cuts it;
    * every configured secret: each API key, token, secret or password in
      the `:ex_athena` config, in the provider registry and in an environment
      variable whose name says it is one, wherever its value appears, and the
      value of any `NAME=value` line whose name says the same.

  The file says at its top what it leaves out.
  """
  use Phoenix.Component

  alias ExAthena.Web.{Trace, TraceComponents}

  @content_args ~w(content new_string old_string patch new_text old_text)
  @write_tools ~w(write edit apply_patch)
  @secret_name ~r/(api[_-]?key|token|secret|passw(or)?d|credential|private[_-]?key|(^|_)key$|(^|[_-])(pat|auth|cred)([_-]|$))/i
  @secret_word "[A-Za-z0-9_.-]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)"
  # `FOO_TOKEN=v`, `export FOO_TOKEN="v"`, `FOO_TOKEN: v`, `"api_key": "v"`.
  @secret_line Regex.compile!(
                 ~S{(["']?\b} <>
                   @secret_word <> ~S{["']?\s*[:=]\s*)("[^"\n]*"|'[^'\n]*'|[^\s"',;\n]+)},
                 "i"
               )
  @bearer ~r/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]{8,}/i
  # `Authorization: v`, `--api-key v` and the password in `scheme://user:pass@`.
  # Everything after the header name to the end of the line: schemes such as
  # Digest carry the credential after commas and quotes.
  @auth_header ~r/\b((?:Proxy-)?Authorization["']?\s*:\s*)([^\n]+)/i
  @cli_flag ~r/(--?[A-Za-z-]*(?:key|token|secret|password)[ =])([^\s"',;]+)/i
  @url_password ~r{(://[^:/\s@]+:)([^@\s/]+)(@)}
  # Tools whose output is kept, cut at 2,000 characters: commands, helpers,
  # questions and the web. Every other tool's output (a read, a search, an
  # MCP server's tool) can be a file's text, so it is left out.
  @kept_output_tools ~w(bash gh spawn_agent ask_user todo_write finish plan_mode
                        set_working_folder web_search web_fetch usage_rules skill
                        write edit apply_patch)
  # Shorter values are too common to scrub without mangling ordinary text.
  @min_secret_chars 6
  @redacted "[redacted]"

  @doc "The HTML file for `session`, with `helpers` as `Trace.helper_records/1` reads them."
  @spec html(map(), map()) :: String.t()
  def html(session, helpers \\ %{}) do
    secrets = secrets()

    session = session |> leave_out_file_contents() |> redact(secrets)

    helpers =
      helpers
      |> Map.new(fn {id, records} -> {id, Enum.map(records, &digest_only/1)} end)
      |> redact(secrets)

    trace = Trace.build(session, helpers)

    %{trace: trace, css: css(), title: title(trace)}
    |> document()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> scrub_rendered(secrets)
  end

  @doc "A file name for `session`'s trace: `trace-<id>.html`."
  @spec file_name(map()) :: String.t()
  def file_name(session) do
    id = session |> Map.get(:id) |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "")
    "trace-#{if id == "", do: "session", else: id}.html"
  end

  defp title(%{id: id}) when is_binary(id), do: "Trace · #{id}"
  defp title(_trace), do: "Trace"

  defp document(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:" />
        <title>{@title}</title>
        <style><%= Phoenix.HTML.raw(@css) %></style>
      </head>
      <body class="trace-file">
        <div class="trace-notice" id="trace-export-notice">
          Saved from ExAthena. This file leaves out file contents and any output past its first
          2,000 characters, and replaces configured keys and tokens with [redacted], because a
          session can hold code and secrets.
        </div>
        <TraceComponents.trace_panel trace={@trace} interactive={:static} />
        <script><%= Phoenix.HTML.raw(script()) %></script>
      </body>
    </html>
    """
  end

  # ── What the file leaves out ──────────────────────────────────────

  defp leave_out_file_contents(session) do
    stream = List.wrap(Map.get(session, :details_stream))

    read_ids =
      for %{type: :tool_call, payload: %{name: name, tool_call_id: id}} <- stream,
          to_string(name) not in @kept_output_tools,
          into: MapSet.new(),
          do: id

    Map.put(session, :details_stream, Enum.map(stream, &leave_out(&1, read_ids)))
  end

  defp leave_out(%{type: :tool_call, payload: %{arguments: args} = p} = e, _ids)
       when is_map(args) do
    args =
      Map.new(args, fn {k, v} ->
        if to_string(k) in @content_args, do: {k, "[file contents left out]"}, else: {k, v}
      end)

    %{e | payload: %{p | arguments: args}}
  end

  defp leave_out(%{type: :tool_result, payload: %{tool_call_id: id} = p} = e, ids) do
    if MapSet.member?(ids, id),
      do: %{e | payload: %{p | content: "[file contents left out]"}},
      else: e
  end

  defp leave_out(entry, _ids), do: entry

  # A helper's journal keeps each call's arguments as a cut digest, which can
  # hold a file's text and the first part of a key, so the file shows only the
  # path a call named.
  defp digest_only(%{"ev" => "tool_call"} = record) do
    if record["name"] in @write_tools or is_binary(record["args"]),
      do: Map.put(record, "args", record["path"] || "[arguments left out]"),
      else: record
  end

  defp digest_only(record), do: record

  @doc false
  # Every configured secret value, longest first so a key that contains
  # another is replaced whole.
  def secrets do
    config = :ex_athena |> Application.get_all_env() |> named_secrets()

    env =
      for {name, value} <- System.get_env(), Regex.match?(@secret_name, name), do: value

    registry = registry_secrets()
    named_env = for name <- env_names(), value = System.get_env(name), do: value

    (config ++ env ++ registry ++ named_env ++ stored_secrets())
    |> Enum.map(&printable/1)
    |> Enum.filter(&(is_binary(&1) and String.length(&1) >= @min_secret_chars))
    |> Enum.flat_map(&forms/1)
    |> Enum.uniq()
    |> Enum.sort_by(&(-String.length(&1)))
  end

  # A key can sit in the text escaped as Elixir, JSON or HTML would print it.
  defp forms(secret) do
    [
      secret,
      secret |> inspect() |> String.slice(1..-2//1),
      secret |> Jason.encode!() |> String.slice(1..-2//1),
      secret |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    ]
  end

  # Settings that NAME the environment variable holding a key.
  defp env_names do
    for {k, v} <- flatten(Application.get_all_env(:ex_athena) ++ registry_specs()),
        k in [:api_key_env, "api_key_env"],
        is_binary(v),
        do: v
  end

  defp flatten(term) when is_list(term), do: Enum.flat_map(term, &flatten/1)
  defp flatten({k, v}), do: [{k, v} | flatten(v)]
  defp flatten(%_{} = struct), do: struct |> Map.from_struct() |> Map.to_list() |> flatten()
  defp flatten(map) when is_map(map), do: map |> Map.to_list() |> flatten()
  defp flatten(_), do: []

  # The web UI's own sign-in token and signing key, kept on disk beside the
  # sessions.
  defp stored_secrets do
    dir = ExAthena.Web.Sessions.base_dir()

    # `mix athena.web` keeps its token at a fixed path, the key in the web dir.
    paths = [
      Path.expand("~/.ex_athena/web/token"),
      Path.join(dir, "token"),
      Path.join(dir, "secret.key")
    ]

    for path <- Enum.uniq(paths), {:ok, body} <- [File.read(path)], do: String.trim(body)
  end

  defp printable(list) when is_list(list) do
    if List.ascii_printable?(list), do: List.to_string(list), else: list
  end

  defp printable(other), do: other

  # The registry runs only under the chat front ends; without it there is
  # nothing registered to hide.
  defp registry_secrets, do: named_secrets(registry_specs())

  defp registry_specs do
    ExAthena.ProviderRegistry.list()
  catch
    :exit, _ -> []
  end

  # Values under a name that says it is a secret, at any depth.
  defp named_secrets(term), do: named_secrets(term, false)

  defp named_secrets(value, true) when is_binary(value), do: [value]
  defp named_secrets(value, false) when is_binary(value), do: url_secrets(value)

  defp named_secrets(value, true) when is_list(value) and value != [] do
    if List.ascii_printable?(value),
      do: [List.to_string(value)],
      else: named_secrets(value, false)
  end

  defp named_secrets(map, secret?) when is_map(map) and not is_struct(map) do
    Enum.flat_map(map, fn
      {k, v} when k in [:headers, "headers"] ->
        named_secrets_in_headers(v) ++ named_secrets(v, secret?)

      {k, v} ->
        named_secrets(v, secret?(k, secret?))
    end)
  end

  defp named_secrets(%_{} = struct, secret?),
    do: struct |> Map.from_struct() |> named_secrets(secret?)

  defp named_secrets(list, secret?) when is_list(list) do
    Enum.flat_map(list, fn
      {k, v} -> named_secrets(v, secret?(k, secret?))
      v -> named_secrets(v, secret?)
    end)
  end

  defp named_secrets(_value, _secret?), do: []

  # An MCP server's headers carry its credential under a name of the server's
  # choosing (`Authorization`, `X-Api-Key`), so every header counts but the
  # ones that only describe the request.
  @plain_headers ~w(accept accept-encoding accept-language content-type content-length
                    user-agent cache-control connection host origin referer)

  defp secret?(k, inherited), do: inherited or secret_name?(k)

  defp named_secrets_in_headers(headers) when is_map(headers) or is_list(headers) do
    for {name, value} <- headers,
        is_binary(value),
        String.downcase(to_string(name)) not in @plain_headers,
        part <- [value | after_scheme(value)],
        do: part
  end

  defp named_secrets_in_headers(_headers), do: []

  # `Bearer abc` is also printed as plain `abc`.
  defp after_scheme(value) do
    case String.split(value, ~r/\s+/, parts: 2) do
      [scheme, rest] ->
        if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9-]*\z/, scheme), do: [rest], else: []

      _ ->
        []
    end
  end

  # A URL can carry its credential: the password in `user:pass@`, or a query
  # value under a name that says it is one (`?auth=…`, `?api_key=…`).
  defp url_secrets(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme} = uri} when is_binary(scheme) ->
        password =
          case uri.userinfo && String.split(uri.userinfo, ":", parts: 2) do
            [_user, pass] -> [pass]
            _ -> []
          end

        query =
          for {k, v} <- URI.decode_query(uri.query || ""),
              Regex.match?(@secret_name, k) or String.downcase(k) in ~w(auth sig signature),
              do: v

        password ++ query

      _ ->
        []
    end
  end

  defp secret_name?(k) when is_atom(k) or is_binary(k),
    do: Regex.match?(@secret_name, to_string(k))

  defp secret_name?(_k), do: false

  defp redact(term, secrets) when is_binary(term), do: scrub(term, secrets)

  # Times stay as they are: the drawing reads them.
  defp redact(%m{} = time, _secrets) when m in [DateTime, NaiveDateTime, Date, Time], do: time

  defp redact(%_{} = struct, secrets),
    do: struct |> Map.from_struct() |> redact(secrets)

  defp redact(map, secrets) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, redact(v, secrets)} end)

  defp redact(list, secrets) when is_list(list), do: Enum.map(list, &redact(&1, secrets))

  defp redact({a, b}, secrets), do: {redact(a, secrets), redact(b, secrets)}
  defp redact(other, _secrets), do: other

  # On session text, before it is drawn: every known secret, then the value
  # of any line or header that says it holds one.
  defp scrub(text, secrets) do
    text = Enum.reduce(secrets, text, &String.replace(&2, &1, @redacted))
    text = Regex.replace(@secret_line, text, "\\1" <> @redacted)
    text = Regex.replace(@bearer, text, "\\1 " <> @redacted)
    text = Regex.replace(@auth_header, text, "\\1" <> @redacted)
    text = Regex.replace(@cli_flag, text, "\\1" <> @redacted)
    Regex.replace(@url_password, text, "\\1" <> @redacted <> "\\3")
  end

  # On the finished file: known secrets only, in its text only. A pattern
  # could match across the markup, and a secret that is an ordinary word
  # ("details") would rename a class the click script reads.
  @markup ~r{<script\b.*?</script>|<style\b.*?</style>|<[^>]*>}s

  defp scrub_rendered(html, secrets) do
    @markup
    |> Regex.split(html, include_captures: true)
    |> Enum.map_join(fn
      "<" <> _ = markup -> markup
      text -> Enum.reduce(secrets, text, &String.replace(&2, &1, @redacted))
    end)
  end

  # ── Inlined assets ────────────────────────────────────────────────

  # The page's colours, the Activity log's text block and the Trace tab's own
  # rules, read from the files the web UI serves, so the file looks like the
  # tab and the two cannot drift apart.
  defp css do
    app = File.read!(static("app.css"))
    root = Regex.run(~r/^:root \{.*?^\}/ms, app) |> List.first("")
    pre = Regex.run(~r/^\.detail-pre \{.*?^\}/ms, app) |> List.first("")

    Enum.join([root, base_css(), pre, File.read!(static("trace.css"))], "\n")
  end

  defp static(name),
    do: Application.app_dir(:ex_athena, Path.join(["priv", "web", "static", name]))

  defp base_css do
    """
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: var(--bg); color: var(--text); font-family: var(--font-ui); padding: 16px; }
    .details-empty { color: var(--muted); padding: 24px; text-align: center; }
    .trace-file > .trace-notice { font-family: var(--font-mono); font-size: 11px; margin-bottom: 12px; }
    """
  end

  # Opens the details of the mark (or the turn a note names) that was clicked,
  # and closes the one before. No network, no storage.
  defp script do
    """
    (function () {
      var open = null;
      document.addEventListener("click", function (ev) {
        var el = ev.target.closest("[data-mark]");
        if (!el) return;
        var id = el.getAttribute("data-mark");
        var detail = null;
        document.querySelectorAll(".trace-details").forEach(function (d) {
          if ((" " + d.getAttribute("data-turns") + " ").indexOf(" " + id + " ") >= 0) detail = d;
        });
        if (open) open.hidden = true;
        document.querySelectorAll(".trace-mark.is-selected").forEach(function (m) { m.classList.remove("is-selected"); });
        if (!detail || detail === open) { open = null; return; }
        detail.hidden = false;
        open = detail;
        var mark = document.getElementById("trace-mark-" + detail.id.replace("trace-detail-", ""));
        if (mark) mark.classList.add("is-selected");
        detail.scrollIntoView({ block: "nearest" });
      });
    })();
    """
  end
end
