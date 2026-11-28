defmodule ExAthena.Tools.ReadSummaryTest do
  # Not async: the request queue and the app env are global.
  use ExUnit.Case, async: false

  alias ExAthena.{RequestQueue, Response, ToolContext}
  alias ExAthena.Tools.ReadSummary

  setup do
    dir = Path.join(System.tmp_dir!(), "read_summary_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for n <- 1..3, do: File.write!(Path.join(dir, "f#{n}.ex"), "defmodule F#{n} do\nend\n")

    tools_before = Application.fetch_env(:ex_athena, :tools)
    Application.put_env(:ex_athena, :request_queue, enabled: true)
    start_supervised!(RequestQueue)

    on_exit(fn ->
      Application.delete_env(:ex_athena, :request_queue)
      Application.delete_env(:ex_athena, :mock)
      restore_env(:tools, tools_before)
      File.rm_rf!(dir)
    end)

    ctx = ToolContext.new(cwd: dir, assigns: %{spawn_agent_opts: [provider: :mock]})
    {:ok, ctx: ctx}
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:ex_athena, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:ex_athena, key)

  # A provider with one slot whose responder reports itself and then waits
  # for the test to let it finish, so the test controls how long a summary
  # "takes" with messages, never with time.
  defp one_slot_provider(test_pid) do
    responder = fn _request ->
      send(test_pid, {:summarizing, self()})

      receive do
        :finish -> %Response{text: "Purpose: a module", provider: :mock, finish_reason: :stop}
      end
    end

    Application.put_env(:ex_athena, :mock,
      request_queue: [max_depth: 1],
      mock: [responder: responder]
    )
  end

  test "summaries asked for together wait for the model and run one at a time", %{ctx: ctx} do
    one_slot_provider(self())

    tasks =
      for n <- 1..3 do
        Task.async(fn -> ReadSummary.execute(%{"path" => "f#{n}.ex"}, ctx) end)
      end

    for _ <- 1..3 do
      assert_receive {:summarizing, pid}, 5_000
      # Only one summary is in flight: nobody else has started.
      refute_receive {:summarizing, _}, 50
      send(pid, :finish)
    end

    for task <- tasks do
      assert {:ok, "[Summary: " <> _ = summary} = Task.await(task, 5_000)
      assert summary =~ "Purpose: a module"
    end
  end

  test "a summary that cannot get the model in time tells the model to read the file",
       %{ctx: ctx} do
    one_slot_provider(self())
    Application.put_env(:ex_athena, :tools, read_summary_queue_wait_ms: 50)
    :ok = RequestQueue.acquire(:mock)

    assert {:error, message} = ReadSummary.execute(%{"path" => "f1.ex"}, ctx)
    assert message =~ "busy"
    assert message =~ "read"
    refute message =~ "request_queue_timeout"
  end
end
