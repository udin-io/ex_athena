defmodule ExAthena.Storage.SweeperTuningTest do
  # async: false — mutates the :storage application env, which is global.
  use ExUnit.Case, async: false

  alias ExAthena.Storage.Sweeper

  @day 24 * 60 * 60

  setup do
    previous = Application.get_env(:ex_athena, :storage)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ex_athena, :storage)
        value -> Application.put_env(:ex_athena, :storage, value)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "a retention of zero keeps the history forever", %{tmp_dir: tmp} do
    Application.put_env(:ex_athena, :storage,
      session_retention_days: 0,
      file_history_retention_days: 0
    )

    sessions = stale_dir(Path.join(tmp, ".exathena/sessions"))
    history = stale_dir(Path.join(tmp, ".exathena/file-history"))

    assert :ok = Sweeper.run(cwd: tmp)

    assert File.exists?(sessions)
    assert File.exists?(history)
  end

  @tag :tmp_dir
  test "a shortened retention reaps what the default would have kept", %{tmp_dir: tmp} do
    Application.put_env(:ex_athena, :storage, session_retention_days: 1)

    sessions = stale_dir(Path.join(tmp, ".exathena/sessions"))
    history = stale_dir(Path.join(tmp, ".exathena/file-history"))

    assert :ok = Sweeper.run(cwd: tmp)

    refute File.exists?(sessions)
    assert File.exists?(history)
  end

  # Two days old: past a one-day retention, well inside the 30-day default.
  defp stale_dir(root) do
    dir = Path.join(root, "session-id")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "w1.jsonl"), "{}\n")
    File.touch!(Path.join(dir, "w1.jsonl"), System.os_time(:second) - 2 * @day)
    File.touch!(dir, System.os_time(:second) - 2 * @day)
    dir
  end
end
