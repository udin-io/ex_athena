defmodule ExAthena.Storage.SweeperTest do
  use ExUnit.Case, async: true

  alias ExAthena.Storage.Sweeper

  @day 24 * 60 * 60

  describe "sweep/2" do
    @tag :tmp_dir
    test "removes a session whose newest file is past the threshold", %{tmp_dir: tmp} do
      root = Path.join(tmp, "sessions")
      stale = session_tree(root, "stale", 45)

      assert {:ok, removed} = Sweeper.sweep(root, 30 * @day)

      refute File.exists?(stale)
      assert removed == [stale]
    end

    @tag :tmp_dir
    test "keeps what is just under the threshold and removes what is just over", %{tmp_dir: tmp} do
      root = Path.join(tmp, "sessions")
      young = session_tree(root, "young", 29)
      old = session_tree(root, "old", 31)

      assert {:ok, removed} = Sweeper.sweep(root, 30 * @day)

      assert File.exists?(young)
      refute File.exists?(old)
      assert removed == [old]
    end

    @tag :tmp_dir
    test "keeps a session directory whose own mtime is stale but whose contents are fresh",
         %{tmp_dir: tmp} do
      root = Path.join(tmp, "sessions")
      dir = Path.join(root, "resumed")
      journal = Path.join(dir, "journal")
      File.mkdir_p!(journal)
      File.write!(Path.join(journal, "w1.ndjson"), "{}\n")

      # A session resumed after a month: the tree was created long ago, so every
      # directory carries an old mtime, but the worker journal was appended to
      # minutes ago.
      age(Path.join(journal, "w1.ndjson"), 0)
      age(journal, 60)
      age(dir, 60)

      assert {:ok, []} = Sweeper.sweep(root, 30 * @day)
      assert File.exists?(Path.join(journal, "w1.ndjson"))
    end

    @tag :tmp_dir
    test "a fresh transcript keeps the worker directory that belongs to it", %{tmp_dir: tmp} do
      root = Path.join(tmp, "sessions")
      dir = session_tree(root, "abc", 45)
      transcript = Path.join(root, "abc.jsonl")
      File.write!(transcript, "{}\n")
      age(transcript, 1)

      assert {:ok, []} = Sweeper.sweep(root, 30 * @day)

      assert File.exists?(dir)
      assert File.exists?(transcript)
    end

    @tag :tmp_dir
    test "a fresh worker directory keeps the transcript that belongs to it", %{tmp_dir: tmp} do
      root = Path.join(tmp, "sessions")
      dir = session_tree(root, "abc", 0)
      transcript = Path.join(root, "abc.jsonl")
      File.write!(transcript, "{}\n")
      age(transcript, 45)

      assert {:ok, []} = Sweeper.sweep(root, 30 * @day)

      assert File.exists?(dir)
      assert File.exists?(transcript)
    end

    @tag :tmp_dir
    test "removes a stale transcript and its worker directory together", %{tmp_dir: tmp} do
      root = Path.join(tmp, "sessions")
      dir = session_tree(root, "abc", 45)
      transcript = Path.join(root, "abc.jsonl")
      File.write!(transcript, "{}\n")
      age(transcript, 45)

      assert {:ok, removed} = Sweeper.sweep(root, 30 * @day)

      refute File.exists?(dir)
      refute File.exists?(transcript)
      assert Enum.sort(removed) == Enum.sort([dir, transcript])
    end

    @tag :tmp_dir
    test "keeps everything when the max age is zero", %{tmp_dir: tmp} do
      root = Path.join(tmp, "sessions")
      ancient = session_tree(root, "ancient", 4_000)

      assert {:ok, []} = Sweeper.sweep(root, 0)
      assert File.exists?(ancient)
    end

    @tag :tmp_dir
    test "is a no-op on a root that does not exist", %{tmp_dir: tmp} do
      assert {:ok, []} = Sweeper.sweep(Path.join(tmp, "nope"), 30 * @day)
    end

    @tag :tmp_dir
    test "removes a stale symlink without touching what it points at", %{tmp_dir: tmp} do
      root = Path.join(tmp, "sessions")
      File.mkdir_p!(root)
      target = Path.join(tmp, "live")
      File.mkdir_p!(target)
      File.write!(Path.join(target, "keep.txt"), "keep me")

      link = Path.join(root, "linked")
      :ok = File.ln_s(target, link)
      age_link(link, 45)

      assert {:ok, [^link]} = Sweeper.sweep(root, 30 * @day)

      refute File.exists?(link)
      assert File.read!(Path.join(target, "keep.txt")) == "keep me"
    end
  end

  # A session tree as the writers build it: worker transcripts under
  # `sidechains/`, worker journals under `journal/`. Every entry is aged
  # `days` old, deepest first so no later write refreshes a parent.
  defp session_tree(root, id, days) do
    dir = Path.join(root, id)
    sidechains = Path.join(dir, "sidechains")
    journal = Path.join(dir, "journal")
    File.mkdir_p!(sidechains)
    File.mkdir_p!(journal)
    File.write!(Path.join(sidechains, "w1.jsonl"), "{}\n")
    File.write!(Path.join(journal, "w1.ndjson"), "{}\n")

    for path <- [
          Path.join(sidechains, "w1.jsonl"),
          Path.join(journal, "w1.ndjson"),
          sidechains,
          journal,
          dir
        ] do
      age(path, days)
    end

    dir
  end

  defp age(path, days), do: File.touch!(path, System.os_time(:second) - days * @day)

  # `File.touch!/2` follows a symlink and ages its target. Aging the link
  # itself needs `touch -h`, which is what proves the sweep reads the link
  # rather than what it points at.
  defp age_link(path, days) do
    stamp =
      (System.os_time(:second) - days * @day)
      |> DateTime.from_unix!()
      |> Calendar.strftime("%Y%m%d%H%M.%S")

    {_, 0} = System.cmd("touch", ["-h", "-t", stamp, path])
  end
end
