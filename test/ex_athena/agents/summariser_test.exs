defmodule ExAthena.Agents.SummariserTest do
  @moduledoc """
  The report is built from the transcript, not caught from the last message.

  Issue 251: a worker's report was whatever it happened to say last. Worker
  `subagent_fqB0WqCf` said "delivered in the previous turn" and the map it had
  written went nowhere. Reading the transcript instead removes the whole class
  of failure — a worker that summarises itself, runs out of clock or is killed
  still yields a report built from what it actually said.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.{Summariser, Transcript}
  alias ExAthena.Response

  @map "ROUTES live in lib/ex_athena/web/router.ex and there is no QR library anywhere."
  @signoff "The report above is the complete deliverable, delivered in the previous turn."

  setup do
    dir = Path.join(System.tmp_dir!(), "summariser_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, path: Path.join(dir, "subagent_x.ndjson")}
  end

  defp write_turns(path, texts) do
    texts
    |> Enum.with_index()
    |> Enum.each(fn {text, i} ->
      Transcript.write(path, {:assistant_turn, %{i: i, text: text, purpose: :turn}})
    end)

    path
  end

  # Reports back every request it serves, so a test can assert on what the
  # summariser actually asked the model — the prompt IS the contract here.
  defp spy_responder(reply_fun) do
    test_pid = self()

    fn request ->
      send(test_pid, {:summariser_request, request})
      %Response{text: reply_fun.(request), finish_reason: :stop, provider: :mock}
    end
  end

  defp mock_opts(responder), do: [provider: :mock, mock: [responder: responder]]

  defp requests(acc \\ []) do
    receive do
      {:summariser_request, request} -> requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "what it reads" do
    test "the turn the worker later summarised away reaches the model", %{path: path} do
      write_turns(path, [@map, @signoff])

      assert {:ok, report} =
               Summariser.summarise(path, mock_opts(spy_responder(fn _ -> "THE REPORT" end)), [])

      assert report == "THE REPORT"

      # The mid-run turn — the one Result.text threw away — is in the prompt.
      prompt =
        requests() |> List.first() |> then(& &1.messages) |> Enum.map_join(" ", & &1.content)

      assert prompt =~ "no QR library"
      assert prompt =~ @signoff
    end

    test "a transcript with nothing in it is an error, not an empty report", %{path: path} do
      assert {:error, :no_transcript} =
               Summariser.summarise(path, mock_opts(spy_responder(fn _ -> "x" end)), [])
    end
  end

  describe "what it may do" do
    # By construction, not by instruction: a summariser with no tools cannot
    # spawn workers, cannot read the repo, and cannot inherit a todo list.
    test "it is given no tools at all", %{path: path} do
      write_turns(path, [@map])

      assert {:ok, _} =
               Summariser.summarise(path, mock_opts(spy_responder(fn _ -> "report" end)), [])

      assert [request] = requests()
      assert request.tools in [nil, []]
    end

    test "provider settings are carried over but the worker's tools and assigns are not",
         %{path: path} do
      write_turns(path, [@map])

      worker_opts =
        mock_opts(spy_responder(fn _ -> "report" end)) ++
          [
            tools: ["write", "spawn_agent"],
            assigns: %{todos: [%{"content" => "worker todo"}], agent_depth: 3},
            max_iterations: 99
          ]

      assert {:ok, _} = Summariser.summarise(path, worker_opts, [])

      assert [request] = requests()
      assert request.tools in [nil, []]
    end
  end

  describe "chunking" do
    # The acceptance criterion: a transcript longer than one pass is chunked,
    # each chunk summarised into a bounded block, and the blocks combined.
    test "a transcript past the threshold is chunked, then combined", %{path: path} do
      write_turns(path, for(i <- 1..12, do: "turn #{i}: " <> String.duplicate("detail ", 40)))

      reply = fn request ->
        text = Enum.map_join(request.messages, " ", & &1.content)
        if text =~ "BLOCK", do: "COMBINED", else: "BLOCK"
      end

      assert {:ok, report} =
               Summariser.summarise(path, mock_opts(spy_responder(reply)),
                 chunk_chars: 400,
                 block_chars: 500,
                 max_chunks: 8
               )

      calls = requests()

      # More than one chunk pass, plus exactly one combine at the end.
      assert length(calls) > 2
      assert report == "COMBINED"

      last = List.last(calls)
      assert Enum.map_join(last.messages, " ", & &1.content) =~ "BLOCK"
    end

    test "a transcript that fits in one pass is not combined twice", %{path: path} do
      write_turns(path, [@map])

      assert {:ok, "only block"} =
               Summariser.summarise(path, mock_opts(spy_responder(fn _ -> "only block" end)),
                 chunk_chars: 100_000
               )

      assert length(requests()) == 1
    end

    test "each block is capped, so N chunks cannot grow without bound", %{path: path} do
      write_turns(path, for(i <- 1..6, do: "turn #{i}: " <> String.duplicate("detail ", 40)))

      long = String.duplicate("z", 5_000)

      assert {:ok, report} =
               Summariser.summarise(path, mock_opts(spy_responder(fn _ -> long end)),
                 chunk_chars: 400,
                 block_chars: 100,
                 max_chunks: 8
               )

      # The combine pass sees capped blocks, never 5,000 characters each.
      combine_prompt =
        requests() |> List.last() |> then(&Enum.map_join(&1.messages, " ", fn m -> m.content end))

      refute combine_prompt =~ String.duplicate("z", 101)
      assert is_binary(report)
    end

    # Bounding the model runs per worker is the cost rail. Dropping is
    # acceptable; dropping SILENTLY is not — the transcript is still on disk.
    test "past the chunk cap the middle is dropped with a marker naming the transcript",
         %{path: path} do
      write_turns(path, for(i <- 1..40, do: "turn #{i}: " <> String.duplicate("detail ", 40)))

      assert {:ok, _} =
               Summariser.summarise(path, mock_opts(spy_responder(fn _ -> "block" end)),
                 chunk_chars: 300,
                 block_chars: 500,
                 max_chunks: 3
               )

      calls = requests()

      # Three chunk passes plus one combine, never forty.
      assert length(calls) == 4

      combine = List.last(calls)
      text = Enum.map_join(combine.messages, " ", & &1.content)
      assert text =~ "not summarised"
      assert text =~ ~s(source: "transcript")
    end
  end

  describe "when it fails" do
    test "a provider error is reported, not swallowed into a blank report", %{path: path} do
      write_turns(path, [@map])

      assert {:error, _} =
               Summariser.summarise(path, [provider: :mock, mock: [error: :boom]], [])
    end

    test "a model that returns nothing is a failure, so the caller can fall back",
         %{path: path} do
      write_turns(path, [@map])

      assert {:error, :blank_report} =
               Summariser.summarise(path, mock_opts(spy_responder(fn _ -> "   " end)), [])
    end

    # The whole point is that a bad summariser degrades to the worker's text.
    # A linked task would take the spawning tool down with it instead, which
    # loses the worker's report AND the parent's turn.
    test "a summariser that crashes does not take its caller with it", %{path: path} do
      write_turns(path, [@map])

      exploding = fn _request -> exit(:boom) end

      assert {:error, _} = Summariser.summarise(path, mock_opts(exploding))
      assert Process.alive?(self())
    end

    test "the whole summarise is bounded by one timeout", %{path: path} do
      write_turns(path, [@map])

      hangs = fn _request -> Process.sleep(:infinity) end

      assert {:error, :timeout} =
               Summariser.summarise(path, mock_opts(hangs), timeout_ms: 150)
    end
  end
end
