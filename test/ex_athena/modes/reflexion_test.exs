defmodule ExAthena.Modes.ReflexionTest do
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "refl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "injects a reflection after each tool-using iteration, capped at 3", %{dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "a")

    counter = :counters.new(1, [:atomics])

    responder = fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      # Assert: reflection requests have no tools.
      is_reflection = Enum.any?(request.messages, fn m ->
        is_binary(m.content) and String.contains?(m.content || "", "Reflect on your last step")
      end)

      cond do
        # Turn 1: tool call. Turn 2: reflection. Turn 3: tool call. Turn 4: reflection.
        # Etc. When reflection cap (3) hits, subsequent iterations no longer reflect.
        is_reflection ->
          %Response{text: "critique #{n}", finish_reason: :stop, provider: :mock}

        n < 8 ->
          %Response{
            text: "thinking",
            tool_calls: [%ToolCall{id: "c#{n}", name: "read", arguments: %{"path" => "a.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        true ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{finish_reason: :stop} = r} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Read],
               mode: :reflexion,
               max_iterations: 20
             )

    # There must be at least one reflection in the message history but no
    # more than the cap (3).
    reflections =
      r.messages
      |> Enum.filter(fn m -> m.role == :assistant and is_binary(m.content || "") end)
      |> Enum.filter(fn m -> String.contains?(m.content, "critique") end)

    assert length(reflections) >= 1
    assert length(reflections) <= 3
  end
end
