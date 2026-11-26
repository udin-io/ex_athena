defmodule ExAthena.Loop.ContextWindowTest do
  @moduledoc """
  A worker stops on a call that does not fit the model, not on a running total
  of tokens (issue 310). The loop compacts when a request nears the window; if
  the request still does not fit, it stops before the call goes out.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ExAthena.{Loop, Response}

  setup do
    dir = Path.join(System.tmp_dir!(), "ctxwin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp run(prompt, dir, caps) do
    parent = self()

    responder = fn _request ->
      send(parent, :model_called)
      %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    Loop.run(prompt,
      provider: :mock,
      mock: [responder: responder],
      cwd: dir,
      tools: [],
      capabilities: caps
    )
  end

  test "a request that cannot fit the window stops before the call goes out", %{dir: dir} do
    # About 5,000 estimated tokens against a 2,000-token window.
    prompt = String.duplicate("word ", 4_000)

    log =
      capture_log(fn ->
        assert {:ok, result} = run(prompt, dir, %{max_tokens: 2_000})
        assert result.finish_reason == :error_context_window_exceeded
        assert result.error_diagnostic.window == 2_000
      end)

    assert log =~ "does not fit"
    refute_received :model_called
  end

  test "the same request runs when the window holds it", %{dir: dir} do
    prompt = String.duplicate("word ", 4_000)

    assert {:ok, result} = run(prompt, dir, %{max_tokens: 200_000})
    assert result.finish_reason == :stop
    assert_received :model_called
  end

  test "a window the provider only guessed never stops the run", %{dir: dir} do
    prompt = String.duplicate("word ", 4_000)

    assert {:ok, result} = run(prompt, dir, %{max_tokens: 2_000, max_tokens_guess: true})
    assert result.finish_reason == :stop
  end

  test "a window the provider does not report never stops the run", %{dir: dir} do
    prompt = String.duplicate("word ", 4_000)

    assert {:ok, result} = run(prompt, dir, %{max_tokens: nil})
    assert result.finish_reason == :stop
  end
end
