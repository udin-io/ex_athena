# Where do helpers start to work on a local model? (ExAthena issue 321)
#
#   mix run bench/small_models.exs [model ...]    (dev env: the app as shipped)
#
# Runs one three-step task per model, three times, with every builtin tool and
# helpers switched on, against a local Ollama. Prints one line per run and one
# summary line per model. Reads no secrets and writes only a temp project.
#
# A run counts:
#   * todo   - the chat wrote a to-do list (a successful todo_write)
#   * sent   - helpers it sent (spawn_agent calls)
#   * usable - helpers whose result came back without an error
#   * done   - the task's file holds the new function and a test names it
Application.put_env(:ex_athena, :chat, helpers: :on, finish_checks: false)

models =
  case System.argv() do
    [] -> ["qwen2.5-coder:14b", "qwen3.5:latest", "llama3.2:3b"]
    list -> list
  end

runs = String.to_integer(System.get_env("BENCH_RUNS", "3"))

task = """
In this project: add a public function `farewell/1` to lib/greeter.ex that \
returns "Goodbye, <name>!", add a test for it to test/greeter_test.exs, and \
then list every public function in lib/ in your answer. Send a helper to find \
the public functions while you make the change.
"""

project = fn ->
  dir = Path.join(System.tmp_dir!(), "bench321_#{System.unique_integer([:positive])}")
  File.mkdir_p!(Path.join(dir, "lib"))
  File.mkdir_p!(Path.join(dir, "test"))

  File.write!(Path.join(dir, "mix.exs"), """
  defmodule Bench.MixProject do
    use Mix.Project
    def project, do: [app: :bench, version: "0.1.0", elixir: "~> 1.15"]
  end
  """)

  File.write!(Path.join(dir, "lib/greeter.ex"), """
  defmodule Greeter do
    def hello(name), do: "Hello, \#{name}!"
  end
  """)

  File.write!(Path.join(dir, "lib/util.ex"), """
  defmodule Util do
    def shout(text), do: String.upcase(text)
    defp quiet(text), do: String.downcase(text)
  end
  """)

  File.write!(Path.join(dir, "test/greeter_test.exs"), """
  defmodule GreeterTest do
    use ExUnit.Case
    test "hello", do: assert(Greeter.hello("Ann") == "Hello, Ann!")
  end
  """)

  dir
end

calls = fn messages, name ->
  for %{role: :assistant, tool_calls: [_ | _] = cs} <- messages, %{name: ^name} = c <- cs, do: c
end

results_by_id = fn messages ->
  for %{tool_results: [_ | _] = rs} <- messages, r <- rs, into: %{}, do: {r.tool_call_id, r}
end

load = fn -> :os.cmd(~c"sysctl -n vm.loadavg") |> to_string() |> String.trim() end

for model <- models do
  rows =
    for n <- 1..runs do
      dir = project.()
      started = System.monotonic_time(:millisecond)

      result =
        ExAthena.run(task,
          provider: :ollama,
          model: model,
          base_url: System.get_env("OLLAMA_URL", "http://localhost:11434"),
          cwd: dir,
          memory: false,
          # The test config's search adapter is a test-only stub; the task
          # needs no web anyway.
          tools: ExAthena.Tools.builtins() -- [ExAthena.Tools.WebSearch, ExAthena.Tools.WebFetch],
          max_iterations: 25,
          timeout_ms: 600_000
        )

      secs = div(System.monotonic_time(:millisecond) - started, 1000)

      row =
        case result do
          {:ok, r} ->
            by_id = results_by_id.(r.messages)
            spawns = calls.(r.messages, "spawn_agent")
            usable = Enum.count(spawns, &(by_id[&1.id] && by_id[&1.id].is_error != true))
            todos = calls.(r.messages, "todo_write") |> Enum.count(&(by_id[&1.id] && by_id[&1.id].is_error != true))
            src = File.read!(Path.join(dir, "lib/greeter.ex"))
            test = File.read!(Path.join(dir, "test/greeter_test.exs"))
            done = src =~ "def farewell" and test =~ "farewell"

            %{
              todo: todos > 0,
              sent: length(spawns),
              usable: usable,
              done: done,
              end: r.finish_reason,
              tools: r.tool_calls_made,
              said: r.text |> to_string() |> String.slice(0, 120) |> String.replace("\n", " ")
            }

          {:error, reason} ->
            %{todo: false, sent: 0, usable: 0, done: false, end: {:error, reason}, tools: 0, said: ""}
        end

      IO.puts(
        "#{model} run #{n}: todo=#{row.todo} sent=#{row.sent} usable=#{row.usable} " <>
          "done=#{row.done} end=#{inspect(row.end)} tool_calls=#{row.tools} #{secs}s " <>
          "load=#{load.()} said=#{inspect(row.said)}"
      )

      File.rm_rf!(dir)
      row
    end

  IO.puts(
    "#{model} SUMMARY: todo #{Enum.count(rows, & &1.todo)}/#{runs}, " <>
      "helpers sent #{Enum.sum(Enum.map(rows, & &1.sent))}, " <>
      "usable #{Enum.sum(Enum.map(rows, & &1.usable))}, " <>
      "done #{Enum.count(rows, & &1.done)}/#{runs}"
  )
end
