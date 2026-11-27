defmodule ExAthena.Tools.SpawnAgentRunFolderTest do
  @moduledoc """
  An orchestrator that made a git worktree names it once; every worker after
  that starts there (issue 309). Before, a worker's brief ended with "Working
  directory: <main checkout>", its relative greps searched that tree, and an
  auto-delegated "run the suite" step ran the suite on `main`.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, ToolContext}
  alias ExAthena.Agents.RunFolder
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Tools.SetWorkingFolder

  setup do
    base = Path.join(System.tmp_dir!(), "run_folder_#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    worktree = Path.join(base, "wt")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README.md"), "main checkout\n")

    git(repo, ~w(init -q -b main))
    git(repo, ~w(add .))
    git(repo, ~w(-c user.name=t -c user.email=t@example.com commit -q -m init))
    git(repo, ["worktree", "add", "-q", "-b", "feature", worktree])
    File.write!(Path.join(worktree, "marker.txt"), "only in the worktree\n")

    # `git worktree list` prints real paths; a symlinked tmp dir would not match.
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, repo: realpath(repo), worktree: realpath(worktree), base: realpath(base)}
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp realpath(path) do
    {out, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(out)
  end

  defp ctx(repo, opts \\ []) do
    ToolContext.new([cwd: repo, assigns: RunFolder.install(%{})] ++ opts)
  end

  describe "set_working_folder" do
    test "accepts a worktree of the run's repo", %{repo: repo, worktree: worktree} do
      ctx = ctx(repo)

      assert {:ok, text} = SetWorkingFolder.execute(%{"path" => worktree}, ctx)
      assert text =~ worktree
      assert RunFolder.get(ctx.assigns) == worktree
    end

    test "refuses a folder that is not a worktree of the repo", %{repo: repo, base: base} do
      other = Path.join(base, "elsewhere")
      File.mkdir_p!(other)
      ctx = ctx(repo)

      assert {:error, message} = SetWorkingFolder.execute(%{"path" => other}, ctx)
      assert message =~ "not a worktree"
      assert RunFolder.get(ctx.assigns) == nil
    end

    test "refuses a worktree whose folder was deleted", %{repo: repo, worktree: worktree} do
      File.rm_rf!(worktree)
      ctx = ctx(repo)

      assert {:error, message} = SetWorkingFolder.execute(%{"path" => worktree}, ctx)
      assert message =~ "not a worktree"
      assert RunFolder.get(ctx.assigns) == nil
    end

    test "refuses a missing, blank or non-string path", %{repo: repo} do
      ctx = ctx(repo)

      for args <- [%{}, %{"path" => ""}, %{"path" => 7}, %{"path" => false}] do
        assert {:error, message} = SetWorkingFolder.execute(args, ctx)
        assert message =~ "`path` is required"
      end

      assert RunFolder.get(ctx.assigns) == nil
    end

    test "refuses a worktree outside the confinement roots", %{repo: repo, worktree: worktree} do
      ctx = ctx(repo, allowed_roots: [repo])

      assert {:error, message} = SetWorkingFolder.execute(%{"path" => worktree}, ctx)
      assert message =~ "outside the folders"
      assert RunFolder.get(ctx.assigns) == nil
    end

    test "accepts a worktree inside the confinement roots", %{
      repo: repo,
      worktree: worktree,
      base: base
    } do
      ctx = ctx(repo, allowed_roots: [base])

      assert {:ok, _} = SetWorkingFolder.execute(%{"path" => worktree}, ctx)
      assert RunFolder.get(ctx.assigns) == worktree
    end

    test "refuses when the run has nowhere to keep the folder", %{repo: repo, worktree: worktree} do
      ctx = ToolContext.new(cwd: repo, assigns: %{})

      assert {:error, message} = SetWorkingFolder.execute(%{"path" => worktree}, ctx)
      assert message =~ "cannot change its working folder"
    end
  end

  describe "the worker after the folder is set" do
    # Parent: optionally name the folder, then spawn one worker, then stop.
    defp parent_responder(folder) do
      counter = :counters.new(1, [:atomics])

      fn _req ->
        :counters.add(counter, 1, 1)

        case {:counters.get(counter, 1), folder} do
          {1, nil} ->
            spawn_call("c1")

          {1, folder} ->
            %Response{
              text: "using the worktree",
              tool_calls: [
                %ToolCall{
                  id: "c0",
                  name: "set_working_folder",
                  arguments: %{"path" => folder}
                }
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          {2, folder} when folder != nil ->
            spawn_call("c1")

          _ ->
            %Response{text: "all done", finish_reason: :stop, provider: :mock}
        end
      end
    end

    defp spawn_call(id) do
      %Response{
        text: "delegating",
        tool_calls: [
          %ToolCall{id: id, name: "spawn_agent", arguments: %{"prompt" => "check the files"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      }
    end

    # The worker reads a relative path, then reports the brief and what it read.
    defp worker_responder do
      test_pid = self()
      counter = :counters.new(1, [:atomics])

      fn req ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            brief = req.messages |> Enum.find(&(&1.role == :user)) |> Map.fetch!(:content)
            send(test_pid, {:brief, brief})

            %Response{
              text: "reading",
              tool_calls: [
                %ToolCall{id: "r1", name: "read", arguments: %{"path" => "marker.txt"}}
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            read =
              req.messages
              |> Enum.filter(&(&1.role == :tool))
              |> Enum.flat_map(& &1.tool_results)
              |> List.first()

            send(test_pid, {:read_result, read})
            %Response{text: "worker report", finish_reason: :stop, provider: :mock}
        end
      end
    end

    defp run(repo, folder) do
      Loop.run("do the task",
        provider: :mock,
        mock: [responder: parent_responder(folder)],
        tools: [SetWorkingFolder, ExAthena.Tools.SpawnAgent],
        cwd: repo,
        memory: false,
        assigns: %{
          spawn_agent_opts: [
            provider: :mock,
            mock: [responder: worker_responder()],
            memory: false
          ]
        },
        max_iterations: 6
      )
    end

    test "its brief names the worktree alone and its relative read resolves there", %{
      repo: repo,
      worktree: worktree
    } do
      assert {:ok, _} = run(repo, worktree)

      assert_receive {:brief, brief}
      assert brief =~ "Working directory: #{worktree}"
      refute brief =~ repo <> " "
      assert_receive {:read_result, read}
      refute read.is_error
      assert read.content =~ "only in the worktree"
    end

    test "without a named folder the worker still starts in the parent's folder", %{
      repo: repo
    } do
      assert {:ok, _} = run(repo, nil)

      assert_receive {:brief, brief}
      assert brief =~ "Working directory: #{repo}"
      assert_receive {:read_result, read}
      assert read.is_error
    end

    test "a refused folder leaves workers in the parent's folder", %{repo: repo, base: base} do
      assert {:ok, _} = run(repo, base)

      assert_receive {:brief, brief}
      assert brief =~ "Working directory: #{repo}"
    end
  end

  describe "a worktree-isolated worker" do
    test "its brief names its own worktree, not the run folder", %{
      repo: repo,
      worktree: worktree
    } do
      test_pid = self()
      counter = :counters.new(1, [:atomics])

      parent = fn _req ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            %Response{
              text: "worktree ready",
              tool_calls: [
                %ToolCall{id: "c0", name: "set_working_folder", arguments: %{"path" => worktree}}
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          2 ->
            %Response{
              text: "delegating",
              tool_calls: [
                %ToolCall{
                  id: "c1",
                  name: "spawn_agent",
                  arguments: %{"prompt" => "check the files", "agent" => "isolated"}
                }
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            %Response{text: "all done", finish_reason: :stop, provider: :mock}
        end
      end

      worker = fn req ->
        brief = req.messages |> Enum.find(&(&1.role == :user)) |> Map.fetch!(:content)
        [_, folder] = Regex.run(~r/Working directory: (\S+) /, brief)
        send(test_pid, {:isolated_brief_folder, folder, File.dir?(folder)})
        %Response{text: "worker report", finish_reason: :stop, provider: :mock}
      end

      agents = %{
        "isolated" => %ExAthena.Agents.Definition{
          name: "isolated",
          description: "runs in its own worktree",
          isolation: :worktree
        }
      }

      assert {:ok, _} =
               Loop.run("do the task",
                 provider: :mock,
                 mock: [responder: parent],
                 tools: [SetWorkingFolder, ExAthena.Tools.SpawnAgent],
                 cwd: repo,
                 memory: false,
                 assigns: %{
                   agents: agents,
                   spawn_agent_opts: [provider: :mock, mock: [responder: worker], memory: false]
                 },
                 max_iterations: 6
               )

      assert_receive {:isolated_brief_folder, folder, true}
      refute folder == worktree
      refute folder == repo
    end
  end

  describe "an auto-delegated step" do
    # The orchestrator names the worktree and writes todos but never delegates;
    # after two such turns the runtime delegates the first todo itself.
    test "starts in the worktree and its brief names only that folder", %{
      repo: repo,
      worktree: worktree
    } do
      todos = %{"todos" => [%{"content" => "run the full suite", "status" => "pending"}]}
      counter = :counters.new(1, [:atomics])

      responder = fn _req ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            %Response{text: "the plan", finish_reason: :stop, provider: :mock}

          2 ->
            %Response{
              text: "worktree ready",
              tool_calls: [
                %ToolCall{id: "t1", name: "set_working_folder", arguments: %{"path" => worktree}},
                %ToolCall{id: "t2", name: "todo_write", arguments: todos}
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          3 ->
            %Response{
              text: "still organizing",
              tool_calls: [%ToolCall{id: "t3", name: "todo_write", arguments: todos}],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            %Response{text: "done\nCONCLUSION: ok.", finish_reason: :stop, provider: :mock}
        end
      end

      assert {:ok, _} =
               Loop.run("go",
                 provider: :mock,
                 mock: [responder: responder],
                 cwd: repo,
                 memory: false,
                 tools: [ExAthena.Tools.TodoWrite, SetWorkingFolder, ExAthena.Tools.SpawnAgent],
                 mode: :orchestrate,
                 assigns: %{
                   spawn_agent_opts: [
                     provider: :mock,
                     mock: [responder: worker_responder()],
                     memory: false
                   ]
                 }
               )

      assert_receive {:brief, brief}
      assert brief =~ "run the full suite"
      assert brief =~ "Working directory: #{worktree}"
      refute brief =~ repo <> " "
      assert_receive {:read_result, read}
      assert read.content =~ "only in the worktree"
    end
  end
end
