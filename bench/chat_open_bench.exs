# Opens one long chat the old way (the web UI's own term file) and the new
# way (the shared chat record plus the web UI's cached view), A B A B, and
# prints the median of each. Issue 359's guardrail: a chat with a long history
# opens no slower than the web UI opens one today.
#
#     mix run bench/chat_open_bench.exs [turns] [rounds]
#
# Writes only under a fresh folder in the system temp dir, deleted at the end.

alias ExAthena.Messages
alias ExAthena.Messages.{Message, ToolCall, ToolResult}
alias ExAthena.Web.Sessions

{turns, rounds} =
  case System.argv() do
    [t, r] -> {String.to_integer(t), String.to_integer(r)}
    [t] -> {String.to_integer(t), 20}
    [] -> {500, 20}
  end

root = Path.join(System.tmp_dir!(), "ex_athena_chat_open_bench_#{System.unique_integer([:positive])}")
Application.put_env(:ex_athena, :chats_dir, Path.join(root, "chats"))
Application.put_env(:ex_athena, :web_dir, Path.join(root, "web"))

# Each turn: a question, a tool call, its result, and a reply of a few
# hundred characters, like a working chat.
ex =
  Enum.flat_map(1..turns, fn i ->
    [
      Messages.user("question #{i}: " <> String.duplicate("why does it fail? ", 10)),
      Messages.assistant(nil, [%ToolCall{id: "c#{i}", name: "read", arguments: %{"path" => "lib/a#{i}.ex"}}]),
      %Message{role: :tool, tool_results: [%ToolResult{tool_call_id: "c#{i}", content: String.duplicate("line\n", 40)}]},
      Messages.assistant("answer #{i}: " <> String.duplicate("it fails because of x. ", 15))
    ]
  end)

display =
  Enum.flat_map(1..turns, fn i ->
    [
      %{id: "u#{i}", role: :user, text: "question #{i}", images: [], tool_events: [], status: nil},
      %{id: "a#{i}", role: :assistant, text: "answer #{i}", tool_events: [], status: nil, ex_snapshot: Enum.take(ex, i * 4)}
    ]
  end)

data = %{
  id: "bench0000001",
  title: "bench",
  cwd: root,
  provider: "ollama",
  model: "qwen",
  permission: :ask,
  created_at: DateTime.utc_now(),
  updated_at: DateTime.utc_now(),
  display_messages: display,
  ex_messages: ex,
  provider_session_id: nil,
  tool_uis: %{},
  details_stream: [],
  orchestrator: nil
}

# The old store: one term file, read whole and decoded.
old_path = Path.join(root, "old.session")
File.mkdir_p!(root)
File.write!(old_path, :erlang.term_to_binary(data))
old = fn -> old_path |> File.read!() |> :erlang.binary_to_term() end

:ok = Sessions.save(data)
new = fn -> {:ok, _} = Sessions.load("bench0000001") end

# A chat the terminal saved has no web cache: the view is rebuilt.
{:ok, _} = ExAthena.Chats.create(%{id: "bench0000002", cwd: root})
:ok = ExAthena.Chats.sync("bench0000002", ex)
rebuilt = fn -> {:ok, _} = Sessions.load("bench0000002") end
rebuilt.()

# Warm both once, untimed.
old.()
new.()

time = fn f -> f |> :timer.tc() |> elem(0) end

{old_us, new_us, rebuilt_us} =
  Enum.reduce(1..rounds, {[], [], []}, fn _, {o, n, r} ->
    {[time.(old) | o], [time.(new) | n], [time.(rebuilt) | r]}
  end)

median = fn xs -> xs |> Enum.sort() |> Enum.at(div(length(xs), 2)) end
{load, _} = System.cmd("uptime", [])

IO.puts("turns=#{turns} rounds=#{rounds} record=#{File.stat!(ExAthena.Chats.path("bench0000001")).size} bytes")
IO.puts("old term file  median #{div(median.(old_us), 1000)} ms")
IO.puts("record + cache median #{div(median.(new_us), 1000)} ms")
IO.puts("record, no cache median #{div(median.(rebuilt_us), 1000)} ms")
IO.puts("load: " <> String.trim(load))

File.rm_rf!(root)
