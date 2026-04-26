defmodule ExAthena.CheckpointTest do
  use ExUnit.Case, async: true

  alias ExAthena.Checkpoint

  setup do
    cwd = Path.join(System.tmp_dir!(), "checkpoint_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd, sid: "sess-#{System.unique_integer([:positive])}"}
  end

  test "snapshot stores prior file contents under file-history/<sha>/0.bin", %{
    cwd: cwd,
    sid: sid
  } do
    path = Path.join(cwd, "config.txt")
    File.write!(path, "v1")

    assert {:ok, %{version: 0, path: history_dir}} = Checkpoint.snapshot(cwd, sid, path)

    assert File.read!(Path.join(history_dir, "0.bin")) == "v1"
    assert File.read!(Path.join(history_dir, "path")) == Path.expand(path)
  end

  test "snapshot increments versions across multiple edits", %{cwd: cwd, sid: sid} do
    path = Path.join(cwd, "config.txt")

    File.write!(path, "v1")
    {:ok, %{version: 0}} = Checkpoint.snapshot(cwd, sid, path)
    File.write!(path, "v2")
    {:ok, %{version: 1}} = Checkpoint.snapshot(cwd, sid, path)
    File.write!(path, "v3")
    {:ok, %{version: 2, path: dir}} = Checkpoint.snapshot(cwd, sid, path)

    assert File.read!(Path.join(dir, "0.bin")) == "v1"
    assert File.read!(Path.join(dir, "1.bin")) == "v2"
    assert File.read!(Path.join(dir, "2.bin")) == "v3"
  end

  test "snapshot is idempotent when contents haven't changed", %{cwd: cwd, sid: sid} do
    path = Path.join(cwd, "stable.txt")
    File.write!(path, "same")

    {:ok, %{version: 0, path: dir}} = Checkpoint.snapshot(cwd, sid, path)
    {:ok, %{version: 0, path: ^dir}} = Checkpoint.snapshot(cwd, sid, path)

    # Only one .bin file in the dir.
    bins = dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".bin"))
    assert length(bins) == 1
  end

  test "snapshot of a missing file creates a tombstone marker", %{cwd: cwd, sid: sid} do
    path = Path.join(cwd, "ghost.txt")
    refute File.exists?(path)

    {:ok, %{version: 0, path: dir}} = Checkpoint.snapshot(cwd, sid, path)
    assert File.exists?(Path.join(dir, "0.tombstone"))
  end

  test "rewind :code_and_history restores the original file content", %{cwd: cwd, sid: sid} do
    path = Path.join(cwd, "rewind.txt")
    File.write!(path, "original")

    # First snapshot before any edit.
    {:ok, _} = Checkpoint.snapshot(cwd, sid, path)
    File.write!(path, "edited")

    # Now rewind. We don't have a real session log, so rewind reports
    # 0 events_dropped but should still restore the file.
    assert {:ok, %{files_restored: n}} =
             Checkpoint.rewind(sid, :code_and_history,
               cwd: cwd,
               to_uuid: "any-uuid"
             )

    assert n >= 1
    assert File.read!(path) == "original"
  end

  test "rewind :code_and_history removes files that didn't exist at checkpoint time", %{
    cwd: cwd,
    sid: sid
  } do
    path = Path.join(cwd, "new.txt")

    # Snapshot before file existed (creates a tombstone).
    {:ok, _} = Checkpoint.snapshot(cwd, sid, path)
    File.write!(path, "later")

    assert {:ok, _} =
             Checkpoint.rewind(sid, :code_and_history,
               cwd: cwd,
               to_uuid: "any-uuid"
             )

    refute File.exists?(path)
  end

  test "rewind without to_uuid errors", %{sid: sid} do
    assert {:error, :missing_to_uuid} = Checkpoint.rewind(sid, :code_and_history, [])
  end
end
