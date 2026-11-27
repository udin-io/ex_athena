defmodule ExAthena.Modes.ReActSmallModelTest do
  @moduledoc """
  Small models keep a to-do list and start with helpers off (issue 321).
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  @todo_note "## Keep a to-do list"
  @open_steps "[chat runtime: open steps]"

  setup do
    previous = Application.get_env(:ex_athena, :chat)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ex_athena, :chat, previous),
        else: Application.delete_env(:ex_athena, :chat)
    end)

    dir = Path.join(System.tmp_dir!(), "small_model_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp says(text), do: %Response{text: text, finish_reason: :stop, provider: :mock}

  defp tool_turn(calls),
    do: %Response{text: "", tool_calls: calls, finish_reason: :tool_calls, provider: :mock}

  defp scripted(responses) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)
      Enum.at(responses, :counters.get(counter, 1) - 1) || List.last(responses)
    end
  end

  # The first request the model sees: its tool names and system prompt.
  defp first_request(dir, opts) do
    test_pid = self()

    responder = fn request ->
      send(test_pid, {:request, request})
      says("Hi.")
    end

    {:ok, _} =
      Loop.run(
        "hello",
        Keyword.merge(
          [
            provider: :mock,
            mock: [responder: responder],
            cwd: dir,
            tools: :all,
            memory: false
          ],
          opts
        )
      )

    assert_received {:request, request}
    names = Enum.map(request.tools || [], &tool_name/1)
    {names, to_string(request.system_prompt)}
  end

  defp tool_name(%{function: %{name: name}}), do: name
  defp tool_name(%{name: name}), do: name
  defp tool_name(%{"name" => name}), do: name
  defp tool_name(%{"function" => %{"name" => name}}), do: name
  defp tool_name(other), do: inspect(other)

  defp sized(b), do: [capabilities: %{native_tool_calls: true, params_b: b}]

  test "a small model gets the to-do instruction and no helper tool", %{dir: dir} do
    {names, prompt} = first_request(dir, sized(3.0))

    assert "todo_write" in names
    refute "spawn_agent" in names
    refute "read_worker_report" in names
    assert prompt =~ @todo_note
  end

  test "a large model gets the helper tool and no extra instruction", %{dir: dir} do
    {names, prompt} = first_request(dir, sized(14.8))

    assert "spawn_agent" in names
    refute prompt =~ @todo_note
  end

  test "a model whose size is unknown counts as large", %{dir: dir} do
    {names, prompt} = first_request(dir, capabilities: %{native_tool_calls: true})

    assert "spawn_agent" in names
    refute prompt =~ @todo_note
  end

  test "the size where a model counts as small is a setting", %{dir: dir} do
    Application.put_env(:ex_athena, :chat, small_model_below_b: 2)
    {names, prompt} = first_request(dir, sized(3.0))

    assert "spawn_agent" in names
    refute prompt =~ @todo_note
  end

  test "helpers on keeps them for a small model, which still keeps a list", %{dir: dir} do
    Application.put_env(:ex_athena, :chat, helpers: :on)
    {names, prompt} = first_request(dir, sized(3.0))

    assert "spawn_agent" in names
    assert prompt =~ @todo_note
  end

  test "helpers off removes them for every model", %{dir: dir} do
    Application.put_env(:ex_athena, :chat, helpers: :off)
    {names, _} = first_request(dir, sized(70.0))

    refute "spawn_agent" in names
  end

  test "a helper is left as its parent built it", %{dir: dir} do
    {names, prompt} = first_request(dir, sized(3.0) ++ [assigns: %{agent_depth: 1}])

    assert "spawn_agent" in names
    refute prompt =~ @todo_note
  end

  test "a small model that calls a helper anyway is told helpers are off", %{dir: dir} do
    script = [
      tool_turn([%ToolCall{id: "s1", name: "spawn_agent", arguments: %{"prompt" => "look"}}]),
      says("OK.")
    ]

    assert {:ok, result} =
             Loop.run(
               "find the routes",
               [
                 provider: :mock,
                 mock: [responder: scripted(script)],
                 cwd: dir,
                 tools: :all,
                 memory: false
               ] ++ sized(3.0)
             )

    text =
      result.messages
      |> Enum.flat_map(&(&1.tool_results || []))
      |> Enum.map_join("\n", &to_string(&1.content))

    assert text =~ "helpers are switched off"
  end

  describe "a stop with steps still open" do
    defp todos(statuses) do
      tool_turn([
        %ToolCall{
          id: "t#{System.unique_integer([:positive])}",
          name: "todo_write",
          arguments: %{
            "todos" =>
              Enum.with_index(statuses, fn s, i ->
                %{"content" => "step #{i + 1}", "status" => s}
              end)
          }
        }
      ])
    end

    defp run_script(script, dir, opts \\ []) do
      Loop.run(
        "do the three steps",
        Keyword.merge(
          [
            provider: :mock,
            mock: [responder: scripted(script)],
            cwd: dir,
            tools: [ExAthena.Tools.TodoWrite],
            memory: false,
            max_iterations: 10
          ],
          opts
        )
      )
    end

    defp notes(result),
      do: for(%{role: :user, content: c} <- result.messages, is_binary(c), do: c)

    test "is nudged once, and the second stop ends the chat", %{dir: dir} do
      script = [todos(["completed", "pending", "pending"]), says("I will do step 2 next.")]
      assert {:ok, result} = run_script(script, dir)

      nudges = Enum.filter(notes(result), &String.starts_with?(&1, @open_steps))
      assert length(nudges) == 1
      assert hd(nudges) =~ "step 2"
      assert result.finish_reason == :stop
    end

    test "a finished list ends the chat at once", %{dir: dir} do
      assert {:ok, result} = run_script([todos(["completed", "completed"]), says("Done.")], dir)
      refute Enum.any?(notes(result), &String.starts_with?(&1, @open_steps))
    end

    test "a chat with no list is answering a question and is left alone", %{dir: dir} do
      assert {:ok, result} = run_script([says("It is 4.")], dir)
      refute Enum.any?(notes(result), &String.starts_with?(&1, @open_steps))
    end

    test "a read-only chat stops to show its list as the plan", %{dir: dir} do
      script = [todos(["pending", "pending"]), says("Here is the plan.")]
      assert {:ok, result} = run_script(script, dir, phase: :plan)
      refute Enum.any?(notes(result), &String.starts_with?(&1, @open_steps))
    end

    test "a resume of the same request is not nudged again", %{dir: dir} do
      script = [todos(["completed", "pending"]), says("Next is step 2.")]
      assert {:ok, first} = run_script(script, dir)

      assert {:ok, second} =
               Loop.run(nil,
                 provider: :mock,
                 mock: [
                   responder: scripted([todos(["completed", "pending"]), says("Still next.")])
                 ],
                 cwd: dir,
                 tools: [ExAthena.Tools.TodoWrite],
                 memory: false,
                 messages: first.messages
               )

      resumed = Enum.drop(second.messages, length(first.messages))
      refute Enum.any?(notes(%{messages: resumed}), &String.starts_with?(&1, @open_steps))
    end
  end
end
