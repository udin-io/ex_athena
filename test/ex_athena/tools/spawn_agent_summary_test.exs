defmodule ExAthena.Tools.SpawnAgentSummaryTest do
  @moduledoc """
  The acceptance criterion for issue 251's second half: what the parent
  RECEIVES is built from the worker's transcript, not caught from its last
  message.

  Worker `subagent_fqB0WqCf` wrote a codebase map and then handed back 545
  characters saying the map had been "delivered in the previous turn". The
  orchestrator re-spawned: another 838,180 tokens and 16.8 minutes.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Messages.ToolCall
  alias ExAthena.{Loop, Response}

  @map "ROUTES live in lib/ex_athena/web/router.ex. There is no QR library anywhere."
  @signoff "The report above is the complete deliverable, delivered in the previous turn."
  @summary "REPORT BUILT FROM THE TRANSCRIPT: routes in router.ex, no QR library."

  setup do
    base = Path.join(System.tmp_dir!(), "spawn_sum_#{System.unique_integer([:positive])}")
    parent = Path.join(base, "parent")
    worker = Path.join(base, "worker")
    File.mkdir_p!(parent)
    File.mkdir_p!(worker)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, parent: parent, worker: worker}
  end

  defp parent_responder do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "delegating",
            tool_calls: [
              %ToolCall{id: "c1", name: "spawn_agent", arguments: %{"prompt" => "map it"}}
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  # One responder serves both the worker and the summariser, because the
  # summariser runs on the worker's provider by design. They are told apart by
  # the summariser's fixed system prompt — it is the only caller with one.
  defp responder(summariser_reply) do
    fn request ->
      cond do
        summariser?(request) ->
          case summariser_reply.() do
            {:ok, text} -> %Response{text: text, finish_reason: :stop, provider: :mock}
            {:error, reason} -> raise reason
          end

        Enum.any?(request.messages, &(&1.role == :tool)) ->
          %Response{text: @signoff, finish_reason: :stop, provider: :mock}

        true ->
          %Response{
            text: @map,
            tool_calls: [
              %ToolCall{
                id: "w1",
                name: "write",
                arguments: %{"path" => "notes.md", "content" => "x"}
              }
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }
      end
    end
  end

  defp summariser?(%{system_prompt: prompt}) when is_binary(prompt),
    do: prompt =~ "transcript of an agent's run" or prompt =~ "summaries of consecutive"

  defp summariser?(_request), do: false

  defp run(parent, worker, responder, extra_opts \\ [summarise_reports: 1]) do
    Loop.run("map the codebase",
      provider: :mock,
      mock: [responder: parent_responder()],
      tools: [ExAthena.Tools.SpawnAgent],
      cwd: parent,
      memory: false,
      session_id: "parent-session",
      assigns: %{
        spawn_agent_opts:
          [
            cwd: worker,
            provider: :mock,
            mock: [responder: responder],
            tools: ["write"],
            memory: false
          ] ++ extra_opts
      },
      max_iterations: 5
    )
  end

  defp spawn_result(result) do
    result.messages
    |> Enum.filter(&match?(%{role: :tool}, &1))
    |> Enum.flat_map(& &1.tool_results)
    |> List.first()
    |> Map.fetch!(:content)
  end

  test "the parent gets the transcript-built report, not the sign-off",
       %{parent: parent, worker: worker} do
    assert {:ok, result} = run(parent, worker, responder(fn -> {:ok, @summary} end))

    report = spawn_result(result)

    assert report =~ @summary
    # The 545-character pathology: the worker's own last words no longer decide
    # what the parent reads.
    refute report =~ @signoff
  end

  # "If the summariser fails, times out or returns nothing, fall back to the
  # worker's own final message rather than handing back nothing, and say in the
  # report that this happened."
  test "a summariser failure falls back to the worker's own text and says so",
       %{parent: parent, worker: worker} do
    assert {:ok, result} = run(parent, worker, responder(fn -> {:error, "summariser down"} end))

    report = spawn_result(result)

    # Something real still reaches the parent.
    assert report =~ @signoff
    # And the parent is told why it is thin, plus where the rest actually is.
    assert report =~ "summariser"
    assert report =~ "read_worker_report"
    assert report =~ ~s(source: "transcript")
  end

  test "a blank summariser is a failure, not an empty report",
       %{parent: parent, worker: worker} do
    assert {:ok, result} = run(parent, worker, responder(fn -> {:ok, "   "} end))

    report = spawn_result(result)

    assert report =~ @signoff
    assert report =~ "read_worker_report"
  end

  # The knob defaults on; off restores exactly today's behaviour, with no
  # note and no extra model run.
  test "switched off, the worker's own final message is the report",
       %{parent: parent, worker: worker} do
    assert {:ok, result} =
             run(parent, worker, responder(fn -> {:ok, @summary} end), summarise_reports: 0)

    report = spawn_result(result)

    assert report =~ @signoff
    refute report =~ @summary
    refute report =~ "summariser"
  end

  # config/test.exs switches the summariser off so unrelated tests keep their
  # meaning. That must not quietly become what ships: the knob defaults ON.
  test "what ships is on by default" do
    assert %{default: 1} =
             ExAthena.Web.Settings.schema()
             |> Enum.find(&(&1.ns == :agents))
             |> Map.fetch!(:fields)
             |> Enum.find(&(&1.key == :summarise_reports))
  end
end
