defmodule ExAthena.Providers.StableHistoryTest do
  @moduledoc """
  Issue 330. A local server reuses its cache only for the part of the prompt
  that matches the previous request from the start. Qwen3.5-family models on
  Ollama are hybrid (recurrent layers beside attention), so the server cannot
  roll its state back to any position: it restores a checkpoint it saved
  earlier, and a checkpoint survives only while everything before it is
  unchanged. A request that rewrites one earlier reply therefore loses every
  checkpoint after that reply, call after call, and the cached count stays
  flat at the first message.

  So the history a tool loop sends must only grow: every message call N sent
  before its ephemeral tail notes comes back byte for byte in call N+1. This
  drives a real loop through the req_llm adapter against a local stub and
  compares the JSON bodies it posts.
  """
  use ExUnit.Case, async: false

  @turns 4

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    for i <- 1..@turns, do: File.write!(Path.join(dir, "f#{i}.txt"), "contents #{i}")
    {:ok, bypass: Bypass.open(), dir: dir}
  end

  # Each turn answers with reasoning and one tool call, the shape a thinking
  # model on Ollama sends: the text channel is empty on tool turns. The last
  # turn answers in plain text.
  defp stub_turns(bypass) do
    test = self()
    counter = :counters.new(1, [:atomics])

    # The adapter asks an Ollama host for the model's size and context
    # window; this stub has neither.
    Bypass.stub(bypass, "POST", "/api/show", &Plug.Conn.resp(&1, 404, ""))
    Bypass.stub(bypass, "GET", "/api/ps", &Plug.Conn.resp(&1, 404, ""))

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:wire_body, Jason.decode!(raw)})
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      message =
        if n <= @turns do
          %{
            "role" => "assistant",
            "content" => "",
            "reasoning_content" => "Turn #{n}: I should read f#{n}.txt next.",
            "tool_calls" => [
              %{
                "id" => "call_#{n}",
                "type" => "function",
                "function" => %{
                  "name" => "read",
                  "arguments" => Jason.encode!(%{"path" => "f#{n}.txt"})
                }
              }
            ]
          }
        else
          %{"role" => "assistant", "content" => "All files read."}
        end

      body =
        Jason.encode!(%{
          "id" => "chatcmpl-#{n}",
          "object" => "chat.completion",
          "created" => 1_700_000_000,
          "model" => "qwen3.8-27b",
          "choices" => [
            %{
              "index" => 0,
              "message" => message,
              "finish_reason" => if(n <= @turns, do: "tool_calls", else: "stop")
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)
  end

  defp collect_bodies(acc \\ []) do
    receive do
      {:wire_body, body} -> collect_bodies([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The history a body carries: everything up to its last tool result. What
  # follows it is the ephemeral tail (progress ledger, phase and budget notes),
  # rebuilt every call by design.
  defp history(%{"messages" => messages}) do
    last_tool =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {m, _} -> m["role"] == "tool" end)
      |> List.last()

    case last_tool do
      nil -> Enum.take_while(messages, &(&1["role"] in ["system", "user"])) |> Enum.take(2)
      {_, idx} -> Enum.take(messages, idx + 1)
    end
  end

  test "each request repeats the previous request's history byte for byte",
       %{bypass: bypass, dir: dir} do
    stub_turns(bypass)

    assert {:ok, _result} =
             ExAthena.Loop.run("Read every file.",
               provider: :ollama,
               base_url: "http://localhost:#{bypass.port}",
               model: "qwen3.8-27b",
               cwd: dir,
               tools: [ExAthena.Tools.Read]
             )

    bodies = collect_bodies()
    assert length(bodies) == @turns + 1

    bodies
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index(1)
    |> Enum.each(fn {[previous, next], call} ->
      sent = history(previous)
      resent = Enum.take(next["messages"], length(sent))

      first_diff =
        Enum.zip(sent, resent)
        |> Enum.find_index(fn {a, b} -> Jason.encode!(a) != Jason.encode!(b) end)

      assert first_diff == nil,
             "call #{call + 1} rewrote message #{first_diff} of call #{call}'s history:\n" <>
               "  sent:   #{inspect(Enum.at(sent, first_diff || 0))}\n" <>
               "  resent: #{inspect(Enum.at(resent, first_diff || 0))}"
    end)
  end
end
