defmodule ExAthena.Loop.InferenceQueueTest do
  @moduledoc """
  Issue #136 — every mode-internal inference must acquire a RequestQueue
  slot like the main ReAct turn does. On a 1-slot local GPU an unqueued
  reflection/planning/distillation call escapes the gate the queue exists
  to enforce.

  Observed through the queue's public telemetry
  (`[:ex_athena, :request_queue, :acquired]`) — one event per provider
  call when the queue is enabled.
  """
  use ExUnit.Case, async: false

  alias ExAthena.RequestQueue
  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  setup tags do
    test_pid = self()
    handler_id = "inference-queue-#{inspect(tags.test)}"

    :telemetry.attach(
      handler_id,
      [:ex_athena, :request_queue, :acquired],
      fn _name, _measurements, meta, _ -> send(test_pid, {:acquired, meta.provider}) end,
      nil
    )

    Application.put_env(:ex_athena, :request_queue, enabled: true)
    start_supervised!(RequestQueue)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.delete_env(:ex_athena, :request_queue)
    end)

    dir = Path.join(System.tmp_dir!(), "infq_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Characterization: the conclusion-distillation micro-call already queues.
  test "the conclusion distillation micro-call acquires a queue slot", %{dir: dir} do
    File.write!(Path.join(dir, "f.txt"), "x")
    counter = :counters.new(1, [:atomics])

    responder = fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      first_content = request.messages |> List.first() |> Map.get(:content) |> to_string()

      cond do
        first_content =~ "Summarize this reasoning" ->
          %Response{
            text: "the services dir has 6 markdown files",
            finish_reason: :stop,
            provider: :mock
          }

        n == 1 ->
          %Response{
            text: "",
            thinking: "long reasoning about services " <> String.duplicate("x", 300),
            tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "f.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        true ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Read],
               conclusion_summarizer: true,
               memory: false
             )

    assert :counters.get(counter, 1) == 3
    assert_receive {:acquired, :mock}
    assert_receive {:acquired, :mock}
    assert_receive {:acquired, :mock}
    refute_receive {:acquired, :mock}, 50
  end
end
