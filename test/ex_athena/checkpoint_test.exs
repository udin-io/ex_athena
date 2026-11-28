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

  test "restore_files puts back the version a dropped call snapshot", %{cwd: cwd, sid: sid} do
    path = Path.join(cwd, "rewind.txt")
    File.write!(path, "original")

    {:ok, _} = Checkpoint.snapshot(cwd, sid, path, "dropped-call")
    File.write!(path, "edited")

    assert {:ok, 1} = Checkpoint.restore_files(cwd, sid, MapSet.new(), cwd)
    assert File.read!(path) == "original"
  end

  test "restore_files keeps a file only kept calls changed", %{cwd: cwd, sid: sid} do
    path = Path.join(cwd, "kept.txt")
    File.write!(path, "original")

    {:ok, _} = Checkpoint.snapshot(cwd, sid, path, "kept-call")
    File.write!(path, "edited")

    assert {:ok, 0} = Checkpoint.restore_files(cwd, sid, MapSet.new(["kept-call"]), cwd)
    assert File.read!(path) == "edited"
  end

  test "restore_files removes files that did not exist before the dropped call", %{
    cwd: cwd,
    sid: sid
  } do
    path = Path.join(cwd, "new.txt")

    {:ok, _} = Checkpoint.snapshot(cwd, sid, path, "dropped-call")
    File.write!(path, "later")

    assert {:ok, 1} = Checkpoint.restore_files(cwd, sid, MapSet.new(), cwd)
    refute File.exists?(path)
  end

  test "restore_files never picks a version saved without a call id", %{cwd: cwd, sid: sid} do
    path = Path.join(cwd, "anon.txt")
    File.write!(path, "original")

    {:ok, _} = Checkpoint.snapshot(cwd, sid, path)
    File.write!(path, "edited")

    assert {:ok, 0} = Checkpoint.restore_files(cwd, sid, MapSet.new(), cwd)
    assert File.read!(path) == "edited"
  end
end
