defmodule Mix.Tasks.Athena.TraceTest do
  @moduledoc """
  Issue 353: `mix athena.trace <session id>` and the Trace tab's Save button
  write one HTML file that opens with no server. A session can hold code and
  secrets, so the file leaves out file contents, cuts long output and never
  carries a configured key.
  """
  # Not async: it sets the web dir and an API key in the app's config.
  use ExUnit.Case, async: false

  alias ExAthena.Web.Sessions

  @key "sk-trace-test-0123456789abcdef"
  @env_key "env-secret-9876543210zyxw"

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous_dir = Application.get_env(:ex_athena, :web_dir)
    previous_openai = Application.get_env(:ex_athena, :openai)
    Application.put_env(:ex_athena, :web_dir, Path.join(dir, "web"))
    Application.put_env(:ex_athena, :openai, api_key: @key, model: "gpt-test")
    System.put_env("EX_ATHENA_TRACE_TEST_TOKEN", @env_key)

    on_exit(fn ->
      restore(:web_dir, previous_dir)
      restore(:openai, previous_openai)
      System.delete_env("EX_ATHENA_TRACE_TEST_TOKEN")
    end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:ex_athena, key)
  defp restore(key, value), do: Application.put_env(:ex_athena, key, value)

  defp d(id, type, payload, at),
    do: %{id: id, type: type, message_id: "m1", payload: payload, at: at}

  defp save_session(id, dir) do
    long = String.duplicate("x", 2_500) <> "TAIL-MARKER"

    entries = [
      d("u", :user_text, %{text: "check the key #{@key}"}, 0),
      d("i1", :iteration, %{n: 1}, 100),
      d(
        "c1",
        :tool_call,
        %{tool_call_id: "r1", name: "read", arguments: %{"path" => "config/prod.exs"}},
        110
      ),
      d(
        "t1",
        :tool_result,
        %{tool_call_id: "r1", content: "FILE-BODY-MARKER secret stuff", is_error: false},
        120
      ),
      d("i2", :iteration, %{n: 2}, 200),
      d(
        "c2",
        :tool_call,
        %{tool_call_id: "b1", name: "bash", arguments: %{"command" => "env"}},
        210
      ),
      d(
        "t2",
        :tool_result,
        %{
          tool_call_id: "b1",
          content:
            "OPENAI_API_KEY=#{@key}\nHOME_TOKEN=#{@env_key}\nOTHER_PASSWORD=hunter2hunter2\n" <>
              long,
          is_error: false
        },
        220
      ),
      d("i3", :iteration, %{n: 3}, 300),
      d(
        "c3",
        :tool_call,
        %{
          tool_call_id: "w1",
          name: "write",
          arguments: %{"path" => "lib/a.ex", "content" => "WRITE-BODY-MARKER"}
        },
        310
      )
    ]

    Sessions.save(%{
      id: id,
      title: "a traced chat",
      cwd: dir,
      provider: "openai",
      model: "gpt-test",
      permission: "ask",
      created_at: ~U[2026-11-28 10:00:00.000Z],
      updated_at: ~U[2026-11-28 10:05:00.000Z],
      display_messages: [],
      ex_messages: [],
      provider_session_id: nil,
      tool_uis: %{},
      details_stream: Enum.reverse(entries),
      orchestrator: nil
    })
  end

  defp run_task(args) do
    Mix.Tasks.Athena.Trace.run(args)
  end

  test "writes one file that holds every turn's mark", %{tmp_dir: dir} do
    save_session("abc123def456", dir)
    out = Path.join(dir, "out.html")

    run_task(["abc123def456", "--out", out])

    html = File.read!(out)
    doc = LazyHTML.from_document(html)

    assert doc |> LazyHTML.query("#trace-lane-chat [data-mark]") |> Enum.count() == 3
    assert doc |> LazyHTML.query(".trace-details[hidden]") |> Enum.count() == 3
    assert html =~ "<style>"
    refute html =~ ~r/(src|href)="https?:/
    assert_received {:mix_shell, :info, [line]}
    assert line =~ out
  end

  test "the file is readable by its owner only until they share it", %{tmp_dir: dir} do
    save_session("abc123def456", dir)
    out = Path.join(dir, "out.html")

    run_task(["abc123def456", "--out", out])

    assert Bitwise.band(File.stat!(out).mode, 0o077) == 0
  end

  test "a configured API key never appears in the file", %{tmp_dir: dir} do
    save_session("abc123def456", dir)
    out = Path.join(dir, "out.html")

    run_task(["abc123def456", "--out", out])

    html = File.read!(out)
    for secret <- ExAthena.Web.TraceExport.secrets(), do: refute(html =~ secret)
    refute html =~ @key
    refute html =~ @env_key
    refute html =~ "hunter2hunter2"
    assert html =~ "[redacted]"
  end

  test "file contents are left out and long output is cut with a note", %{tmp_dir: dir} do
    save_session("abc123def456", dir)
    out = Path.join(dir, "out.html")

    run_task(["abc123def456", "--out", out])

    html = File.read!(out)
    refute html =~ "FILE-BODY-MARKER"
    refute html =~ "WRITE-BODY-MARKER"
    refute html =~ "TAIL-MARKER"
    assert html =~ "more characters not shown"
    assert html =~ "leaves out file contents"
  end

  defp export(entries, helpers \\ %{}) do
    session = %{
      id: "s1",
      cwd: nil,
      created_at: ~U[2026-11-28 10:00:00.000Z],
      details_stream: Enum.reverse(entries)
    }

    ExAthena.Web.TraceExport.html(session, helpers)
  end

  defp said(text), do: [d("i", :iteration, %{n: 1}, 0), d("a", :assistant_text, %{text: text}, 1)]

  test "a key written in the forms a session prints it in is redacted" do
    escaped = "pa\"ss\\word-" <> "12345678"

    Application.put_env(:ex_athena, :trace_probe,
      password: escaped,
      secret: "key\#{x}-87654321",
      other: [api_key: ~c"chars-key-777"]
    )

    on_exit(fn -> Application.delete_env(:ex_athena, :trace_probe) end)

    html =
      export(
        said(
          inspect(escaped) <>
            " " <>
            inspect("key\#{x}-87654321") <>
            " " <>
            Jason.encode!(%{x: escaped}) <>
            " chars-key-777\nDB_TOKEN: yaml-value-1\n\"api_key\": \"json-value-2\"\n" <>
            "Authorization: Bearer abcdefghijklmnop\nexport FOO_SECRET=\"quoted-v3\""
        )
      )

    for leak <- [
          "{x}-87654321",
          "word-12345678",
          "chars-key-777",
          "yaml-value-1",
          "json-value-2",
          "abcdefghijklmnop",
          "quoted-v3"
        ],
        do: refute(html =~ leak, "#{leak} reached the file")
  end

  test "a key held in a variable a setting names is redacted" do
    System.put_env("MY_LLM_CRED", "cred-value-4242")
    Application.put_env(:ex_athena, :trace_probe_env, api_key_env: "MY_LLM_CRED")

    on_exit(fn ->
      System.delete_env("MY_LLM_CRED")
      Application.delete_env(:ex_athena, :trace_probe_env)
    end)

    refute export(said("the key is cred-value-4242")) =~ "cred-value-4242"
  end

  test "a key from a provider file is redacted", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "acme.json"),
      ~s({"name":"acme","adapter":"req_llm","api_key":"acme-file-key-99"})
    )

    start_supervised!({ExAthena.ProviderRegistry, providers_dir: dir})

    refute export(said("acme-file-key-99")) =~ "acme-file-key-99"
  end

  test "a helper's write body and a search's results stay out" do
    helpers = %{
      "sub_a" => [
        %{"ev" => "iteration", "i" => 0, "t" => 1},
        %{
          "ev" => "tool_call",
          "id" => "h1",
          "name" => "write",
          "path" => "lib/a.ex",
          "args" => ~s(%{"content" => "HELPER-WRITE-BODY", "path" => "lib/a.ex"}),
          "t" => 2
        }
      ]
    }

    html =
      export(
        [
          d("i", :iteration, %{n: 1}, 0),
          d(
            "g",
            :tool_call,
            %{tool_call_id: "g1", name: "grep", arguments: %{"pattern" => "x"}},
            1
          ),
          d(
            "r",
            :tool_result,
            %{tool_call_id: "g1", content: "lib/a.ex:3: GREP-HIT-LINE", is_error: false},
            2
          ),
          d("s", :subagent_spawn, %{id: "sub_a", prompt: "write it"}, 3)
        ],
        helpers
      )

    refute html =~ "HELPER-WRITE-BODY"
    refute html =~ "GREP-HIT-LINE"
  end

  test "text that looks like a key line never removes the file's own markup" do
    html = export(said("done MY_TOKEN="))

    assert length(Regex.scan(~r/<pre\b/, html)) == length(Regex.scan(~r/<\/pre>/, html))
  end

  test "the drawing in the file matches the tab's, helper lanes included" do
    t0 = DateTime.to_unix(~U[2026-11-28 10:00:00.000Z], :millisecond)
    helpers = %{"sub_a" => [%{"ev" => "iteration", "i" => 0, "t" => t0 + 500}]}

    entries = [
      d("i", :iteration, %{n: 1}, 0),
      d("s", :subagent_spawn, %{id: "sub_a", prompt: "x"}, 10),
      d("e", :subagent_result, %{id: "sub_a", len: 1}, 1_000)
    ]

    doc = LazyHTML.from_document(export(entries, helpers))
    [x] = doc |> LazyHTML.query("#trace-lane-sub_a .trace-mark") |> LazyHTML.attribute("x")
    assert x == "50.0%"
  end

  test "a link at the target is replaced, never followed", %{tmp_dir: dir} do
    save_session("abc123def456", dir)
    target = Path.join(dir, "elsewhere.txt")
    File.write!(target, "keep me")
    link = Path.join(dir, "out.html")
    File.ln_s!(target, link)

    run_task(["abc123def456", "--out", link])

    assert File.read!(target) == "keep me"
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(link)
    assert File.read!(link) =~ "trace-export-notice"
  end

  test "a secret that is an ordinary word leaves the file's markup alone" do
    System.put_env("PROBE_GENERIC_TOKEN", "details")
    on_exit(fn -> System.delete_env("PROBE_GENERIC_TOKEN") end)

    html = export(said("see the details here"))

    assert html =~ ~s(class="trace-details")
    assert html =~ ".trace-details"
    refute html =~ "see the details here"
  end

  test "prose about tokens keeps its words" do
    assert export(said("the token accounting is off")) =~ "the token accounting is off"
  end

  test "an MCP server's headers, environment and address credentials are redacted" do
    Application.put_env(:ex_athena, :mcp_servers, %{
      "remote" => %{
        type: :http,
        url: "https://mcp.example/mcp?auth=urlsecretval9&format=streaming",
        headers: %{"Authorization" => "Bearer mcpheadersecret7", "accept" => "application/json"}
      },
      "local" => %{
        type: :stdio,
        command: "srv",
        environment: %{"API_TOKEN" => "envsecretval5", "GITHUB_PAT" => "ghpatvalue8"}
      }
    })

    on_exit(fn -> Application.delete_env(:ex_athena, :mcp_servers) end)

    html =
      export(
        said(
          "urlsecretval9 mcpheadersecret7 envsecretval5 ghpatvalue8 streaming application/json"
        )
      )

    for leak <- ~w(urlsecretval9 mcpheadersecret7 envsecretval5 ghpatvalue8),
        do: refute(html =~ leak)

    # What only describes a request stays.
    assert html =~ "streaming application/json"
  end

  test "keys in command lines, headers and addresses nobody configured are redacted" do
    html =
      export(
        said(
          "run --api-key sk-cli-123456\nAuthorization: sk-hdr-123456\npostgres://me:dbpass-123@db/x" <>
            "\nAuthorization: Token tokscheme-77\nAuthorization: Digest username=\"u\", response=\"digestval-88\""
        )
      )

    for leak <- ~w(sk-cli-123456 sk-hdr-123456 dbpass-123 tokscheme-77 digestval-88),
        do: refute(html =~ leak)
  end

  test "an MCP tool's output is left out, a command's stays" do
    html =
      export([
        d("i", :iteration, %{n: 1}, 0),
        d("m", :tool_call, %{tool_call_id: "m1", name: "fs_read_file", arguments: %{}}, 1),
        d(
          "mr",
          :tool_result,
          %{tool_call_id: "m1", content: "MCP-FILE-BODY", is_error: false},
          2
        ),
        d("b", :tool_call, %{tool_call_id: "b1", name: "bash", arguments: %{}}, 3),
        d(
          "br",
          :tool_result,
          %{tool_call_id: "b1", content: "COMMAND-OUTPUT", is_error: false},
          4
        )
      ])

    refute html =~ "MCP-FILE-BODY"
    assert html =~ "COMMAND-OUTPUT"
  end

  test "a missing session stops with a message naming it", %{tmp_dir: _dir} do
    assert_raise Mix.Error, ~r/no saved session "nope00000000"/, fn ->
      run_task(["nope00000000"])
    end
  end

  test "an id that is not a session id is refused before any file is read" do
    assert_raise Mix.Error, ~r/not a session id/, fn -> run_task(["../../etc/passwd"]) end
  end
end
