defmodule ExAthena.Loop.InboxTest do
  @moduledoc """
  A message the person sends while the chat runs reaches the run (issue 323).
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "inbox_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp says(text), do: %Response{text: text, finish_reason: :stop, provider: :mock}

  defp tool_turn(calls),
    do: %Response{text: "", tool_calls: calls, finish_reason: :tool_calls, provider: :mock}

  defp read_turn,
    do:
      tool_turn([
        %ToolCall{
          id: "r#{System.unique_integer([:positive])}",
          name: "read",
          arguments: %{"path" => "a.txt"}
        }
      ])

  # An inbox the test fills; each call hands back what is queued and forgets it.
  defp inbox do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    push = fn text -> Agent.update(agent, &(&1 ++ [text])) end
    drain = fn -> Agent.get_and_update(agent, &{&1, []}) end
    {push, drain}
  end

  # Records each request the model sees, and answers from the script.
  defp recording(test_pid, responses, on_call \\ fn _n -> :ok end) do
    counter = :counters.new(1, [:atomics])

    fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:request, n, request.messages})
      on_call.(n)
      Enum.at(responses, n - 1) || List.last(responses)
    end
  end

  defp texts(messages), do: Enum.map(messages, &to_string(&1.content))

  defp run(dir, responder, drain, opts \\ []) do
    File.write!(Path.join(dir, "a.txt"), "hello")

    Loop.run(
      "read a.txt",
      [
        provider: :mock,
        mock: [responder: responder],
        cwd: dir,
        tools: [ExAthena.Tools.Read],
        memory: false,
        inbox: drain,
        on_event: fn event -> send(self(), {:event, event}) end
      ] ++ opts
    )
  end

  test "a message sent mid-run is in the model's next request", %{dir: dir} do
    {push, drain} = inbox()
    test_pid = self()

    responder =
      recording(test_pid, [read_turn(), says("Done.")], fn
        1 -> push.("skip the admin login")
        _ -> :ok
      end)

    assert {:ok, result} = run(dir, responder, drain)

    assert_received {:request, 2, second}
    assert List.last(texts(second)) == "skip the admin login"
    assert "skip the admin login" in texts(result.messages)
  end

  test "it never lands between a tool call and its result", %{dir: dir} do
    {push, drain} = inbox()

    responder =
      recording(self(), [read_turn(), says("Done.")], fn
        1 -> push.("one more thing")
        _ -> :ok
      end)

    assert {:ok, result} = run(dir, responder, drain)

    [call_at] =
      result.messages
      |> Enum.with_index()
      |> Enum.flat_map(fn {m, i} ->
        if m.role == :assistant and m.tool_calls not in [nil, []], do: [i], else: []
      end)

    assert Enum.at(result.messages, call_at + 1).role == :tool
  end

  test "a message sent as the chat stops gives it one more turn", %{dir: dir} do
    {push, drain} = inbox()

    responder =
      recording(self(), [says("Done."), says("Skipped it.")], fn
        1 -> push.("also skip the admin login")
        _ -> :ok
      end)

    assert {:ok, result} = run(dir, responder, drain)

    assert_received {:request, 2, second}
    assert List.last(texts(second)) == "also skip the admin login"
    assert result.text =~ "Skipped it."
  end

  test "the run says which message it took", %{dir: dir} do
    {push, drain} = inbox()
    test_pid = self()

    responder =
      recording(test_pid, [read_turn(), says("Done.")], fn
        1 -> push.("skip the admin login")
        _ -> :ok
      end)

    {:ok, _} =
      Loop.run("read a.txt",
        provider: :mock,
        mock: [responder: responder],
        cwd: dir,
        tools: [ExAthena.Tools.Read],
        memory: false,
        inbox: drain,
        on_event: fn event -> send(test_pid, {:event, event}) end
      )

    assert_received {:event, {:user_message_taken, "skip the admin login"}}
  end

  test "with no turn left, the message waits in the inbox", %{dir: dir} do
    {push, drain} = inbox()

    responder =
      recording(self(), [says("Done.")], fn
        1 -> push.("one more")
        _ -> :ok
      end)

    assert {:ok, result} = run(dir, responder, drain, max_iterations: 1)

    assert result.finish_reason == :stop
    assert drain.() == ["one more"]
  end

  test "a message sent mid-run joins the request the finish checks quote", %{dir: dir} do
    {push, drain} = inbox()

    write =
      tool_turn([
        %ToolCall{id: "w1", name: "write", arguments: %{"path" => "b.ex", "content" => "x"}}
      ])

    responder =
      recording(self(), [write | Enum.map(1..9, &says("Done, take #{&1}."))], fn
        5 -> push.("also cover the admin login")
        _ -> :ok
      end)

    assert {:ok, result} =
             Loop.run("add a login limit",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Write, ExAthena.Tools.Bash],
               memory: false,
               max_iterations: 15,
               inbox: drain
             )

    audits =
      for %{role: :user, content: c} <- result.messages,
          is_binary(c),
          String.starts_with?(c, "[chat runtime: audit check]"),
          do: c

    assert [first, second] = audits
    refute first =~ "admin login"
    assert second =~ "add a login limit"
    assert second =~ "Then: also cover the admin login"
  end

  test "a hook that halts the turn leaves the messages in the inbox", %{dir: dir} do
    {push, drain} = inbox()
    push.("for later")

    hooks = %{PreIteration: [fn _payload, _ctx -> {:halt, :stopped_by_hook} end]}

    assert {:ok, _} = run(dir, recording(self(), [says("Done.")]), drain, hooks: hooks)
    assert drain.() == ["for later"]
  end

  test "a blank message is dropped", %{dir: dir} do
    {push, drain} = inbox()

    responder =
      recording(self(), [read_turn(), says("Done.")], fn
        1 -> push.("   ")
        _ -> :ok
      end)

    assert {:ok, result} = run(dir, responder, drain)
    refute "   " in texts(result.messages)
  end
end
