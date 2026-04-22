defmodule ExAthena.Tools.Bash do
  @moduledoc """
  Executes a shell command via `/bin/sh -c` with a configurable timeout.

  Arguments:

    * `command` (required) — the shell command.
    * `timeout_ms` (optional, default 120_000, max 600_000).

  Returns captured stdout+stderr plus the exit code. Timeouts kill the spawned
  process and surface `{:error, :timeout}` to the loop.

  Runs with `cd: ctx.cwd`, `stderr_to_stdout: true`. No input redirection.
  """

  @behaviour ExAthena.Tool

  @default_timeout 120_000
  @max_timeout 600_000

  @impl true
  def name, do: "bash"

  @impl true
  def description,
    do: "Run a shell command in the working directory. Captures stdout+stderr and the exit code."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        command: %{type: "string"},
        timeout_ms: %{type: "integer", description: "default 120_000, max 600_000"}
      },
      required: ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command} = args, %{cwd: cwd}) when is_binary(command) do
    timeout =
      case Map.get(args, "timeout_ms") do
        t when is_integer(t) and t > 0 -> min(t, @max_timeout)
        _ -> @default_timeout
      end

    run(command, cwd, timeout)
  end

  def execute(_, _), do: {:error, :missing_command}

  defp run(command, cwd, timeout) do
    sh = System.find_executable("sh") || "/bin/sh"

    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", command],
        cd: cwd
      ])

    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, [], deadline)
  end

  defp collect(port, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        kill(port)
        {:error, :timeout}

      true ->
        receive do
          {^port, {:data, data}} ->
            collect(port, [data | acc], deadline)

          {^port, {:exit_status, code}} ->
            body = acc |> Enum.reverse() |> IO.iodata_to_binary()
            {:ok, "exit #{code}\n" <> body}
        after
          remaining ->
            kill(port)
            {:error, :timeout}
        end
    end
  end

  defp kill(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end
