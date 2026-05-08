defmodule ExAthena.Loop.ImplicitDiagnosticsIntegrationTest do
  @moduledoc """
  Round-trip integration test: Loop.run with a fake Edit tool + fake LSP server.
  Verifies the implicit-diagnostics PostToolUse hook augments the tool result
  message and fires telemetry.
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  @fake_server_script Path.expand("../../support/fake_lsp_server.exs", __DIR__)
  @elixir_bin System.find_executable("elixir")

  # Fake edit tool — writes a file and returns success text.
  defmodule FakeEditTool do
    @behaviour ExAthena.Tool
    def name, do: "Edit"
    def description, do: "Edit a file"
    def parallel_safe?, do: false

    def schema do
      %{
        type: "object",
        properties: %{path: %{type: "string"}},
        required: ["path"]
      }
    end

    def execute(%{"path" => path} = _args, _ctx) do
      if File.exists?(path) do
        {:ok, "edited #{Path.basename(path)} (1 replacement)"}
      else
        {:error, "file not found: #{path}"}
      end
    end
  end

  defp setup_lsp_override do
    Application.put_env(:ex_athena, :lsp_servers, %{
      elixir: %{binary: @elixir_bin, args: ["--erl", "-noinput", @fake_server_script]}
    })

    on_exit(fn -> Application.delete_env(:ex_athena, :lsp_servers) end)
  end

  defp start_lsp_supervisor do
    start_supervised!({Registry, keys: :unique, name: ExAthena.Lsp.Registry})

    start_supervised!(
      {DynamicSupervisor, name: ExAthena.Lsp.ClientSupervisor, strategy: :one_for_one}
    )

    start_supervised!(ExAthena.Lsp.Manager)
  end

  defp unique_dir do
    dir = Path.join(System.tmp_dir!(), "impl_int_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp enable_implicit_diagnostics do
    Application.put_env(:ex_athena, :lsp_implicit_diagnostics_enabled, true)
    on_exit(fn -> Application.put_env(:ex_athena, :lsp_implicit_diagnostics_enabled, false) end)
  end

  # Responder that calls Edit on turn 1 then stops on turn 2.
  defp edit_then_stop(file_path) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "t1", name: "Edit", arguments: %{"path" => file_path}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  describe "Edit on .ex file" do
    setup do
      setup_lsp_override()
      start_lsp_supervisor()
      enable_implicit_diagnostics()
      dir = unique_dir()
      {:ok, dir: dir}
    end

    test "tool result message contains both edit output and lsp diagnostics block", %{dir: dir} do
      path = Path.join(dir, "foo.ex")
      File.write!(path, "defmodule Foo do\nend\n")

      assert {:ok, %Result{} = result} =
               Loop.run("fix the file",
                 provider: :mock,
                 mock: [responder: edit_then_stop(path)],
                 cwd: dir,
                 tools: [FakeEditTool]
               )

      tool_msgs = Enum.filter(result.messages, &(&1.role == :tool))
      assert length(tool_msgs) == 1
      [tool_msg] = tool_msgs
      [tr] = tool_msg.tool_results
      assert tr.content =~ "edited foo.ex"
      assert tr.content =~ "[lsp diagnostics]"
      assert tr.content =~ "error"
    end

    test "telemetry stop event fires with had_errors: true", %{dir: dir} do
      test_pid = self()

      :telemetry.attach(
        "integration-diag-#{System.unique_integer()}",
        [:ex_athena, :lsp, :implicit_diagnostics, :stop],
        fn _name, measurements, _meta, _cfg ->
          send(test_pid, {:telemetry_stop, measurements})
        end,
        nil
      )

      path = Path.join(dir, "bar.ex")
      File.write!(path, "defmodule Bar do\nend\n")

      Loop.run("fix the file",
        provider: :mock,
        mock: [responder: edit_then_stop(path)],
        cwd: dir,
        tools: [FakeEditTool]
      )

      assert_receive {:telemetry_stop, measurements}, 5_000
      assert measurements.had_errors == true
    end
  end

  describe "Edit on .md file (no LSP server for extension)" do
    setup do
      setup_lsp_override()
      start_lsp_supervisor()
      enable_implicit_diagnostics()
      dir = unique_dir()
      {:ok, dir: dir}
    end

    test "tool result content is unchanged when no LSP server matches", %{dir: dir} do
      path = Path.join(dir, "README.md")
      File.write!(path, "# heading\n")

      counter = :counters.new(1, [:atomics])

      responder = fn _request ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            %Response{
              text: "",
              tool_calls: [%ToolCall{id: "t1", name: "Edit", arguments: %{"path" => path}}],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            %Response{text: "done", finish_reason: :stop, provider: :mock}
        end
      end

      assert {:ok, %Result{} = result} =
               Loop.run("fix the file",
                 provider: :mock,
                 mock: [responder: responder],
                 cwd: dir,
                 tools: [FakeEditTool]
               )

      [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
      [tr] = tool_msg.tool_results
      assert tr.content =~ "edited README.md"
      refute tr.content =~ "[lsp diagnostics]"
    end
  end
end
