defmodule ExAthena.TelemetryTest do
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Response, Result, Telemetry}
  alias ExAthena.Messages.ToolCall

  setup tags do
    # Each test attaches its own handler — `tags.test` gives a unique handler id.
    test_pid = self()

    handler_id = "test-#{inspect(tags.test)}"

    events = [
      [:ex_athena, :loop, :start],
      [:ex_athena, :loop, :stop],
      [:ex_athena, :loop, :exception],
      [:ex_athena, :chat, :start],
      [:ex_athena, :chat, :stop],
      [:ex_athena, :tool, :start],
      [:ex_athena, :tool, :stop],
      [:ex_athena, :compaction, :stop],
      [:ex_athena, :structured_retry]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, meta, _ ->
        send(test_pid, {:telemetry, name, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    dir = Path.join(System.tmp_dir!(), "tel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "emits loop :start and :stop spans with GenAI-semconv metadata", %{dir: dir} do
    responder = fn _req ->
      %Response{text: "hello", finish_reason: :stop, provider: :mock}
    end

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [],
               conversation_id: "conv-abc",
               model: "mock-1"
             )

    assert_receive {:telemetry, [:ex_athena, :loop, :start], _, start_meta}
    assert start_meta.gen_ai_operation_name == "invoke_agent"
    assert start_meta.gen_ai_conversation_id == "conv-abc"
    assert start_meta.gen_ai_request_model == "mock-1"

    assert_receive {:telemetry, [:ex_athena, :loop, :stop], measurements, stop_meta}
    assert is_integer(measurements.duration_ms)
    assert measurements.duration_ms >= 0
    # the Result is passed as `:result` metadata from Telemetry.span/3
    assert {:ok, %Result{}} = stop_meta.result
  end

  test "emits chat :start / :stop around each provider call", %{dir: dir} do
    responder = fn _req ->
      %Response{text: "done", finish_reason: :stop, provider: :mock}
    end

    assert {:ok, _r} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: []
             )

    assert_receive {:telemetry, [:ex_athena, :chat, :start], _, meta}
    assert meta.gen_ai_operation_name == "chat"

    assert_receive {:telemetry, [:ex_athena, :chat, :stop], m, _}
    assert is_integer(m.duration_ms)
  end

  test "emits tool :start / :stop around tool execution", %{dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "hi")
    counter = :counters.new(1, [:atomics])

    responder = fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "t1", name: "read", arguments: %{"path" => "a.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{finish_reason: :stop, tool_calls_made: 1}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Read]
             )

    assert_receive {:telemetry, [:ex_athena, :tool, :start], _, meta}
    assert meta.gen_ai_operation_name == "execute_tool"
    assert meta.gen_ai_tool_name == "read"
    assert meta.gen_ai_tool_call_id == "t1"

    assert_receive {:telemetry, [:ex_athena, :tool, :stop], m, _}
    assert is_integer(m.duration_ms)
  end

  test "genai_meta/1 translates common keys to GenAI semconv atoms" do
    meta =
      Telemetry.genai_meta(
        operation: "chat",
        provider: :mock,
        request_model: "x-1",
        conversation_id: "c",
        tool_name: "read",
        finish_reasons: :stop,
        unknown_key: "passthrough"
      )

    assert meta.gen_ai_operation_name == "chat"
    assert meta.gen_ai_provider_name == "mock"
    assert meta.gen_ai_request_model == "x-1"
    assert meta.gen_ai_conversation_id == "c"
    assert meta.gen_ai_tool_name == "read"
    assert meta.gen_ai_response_finish_reasons == [:stop]
    assert meta.unknown_key == "passthrough"
  end

  test "span/3 re-raises exceptions and emits :exception event" do
    try do
      Telemetry.span([:ex_athena, :loop], %{}, fn ->
        raise "boom"
      end)
    rescue
      e -> assert e.message == "boom"
    end

    assert_receive {:telemetry, [:ex_athena, :loop, :start], _, _}
    assert_receive {:telemetry, [:ex_athena, :loop, :exception], _, meta}
    assert meta.kind == :error
    assert Exception.message(meta.reason) == "boom"
  end
end
