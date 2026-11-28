defmodule ExAthena.Web.PrivateFilesTest do
  @moduledoc """
  The web UI's signing key, saved chats and recent-project list sit under one
  folder. On a shared machine only the owner may read them.
  """
  use ExUnit.Case, async: false

  alias ExAthena.Web.Sessions
  alias Mix.Tasks.Athena.Web

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:ex_athena, :web_dir)
    dir = Path.join(tmp, "web")
    Application.put_env(:ex_athena, :web_dir, dir)

    on_exit(fn -> Application.put_env(:ex_athena, :web_dir, previous) end)
    %{dir: dir}
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  describe "signing key" do
    test "is written 0600 in a 0700 folder", %{dir: dir} do
      Web.stable_key_base()

      assert mode(Path.join(dir, "secret.key")) == 0o600
      assert mode(dir) == 0o700
    end

    test "a second start reads the same key", %{dir: dir} do
      first = Web.stable_key_base()

      assert Web.stable_key_base() == first
      assert File.read!(Path.join(dir, "secret.key")) == first
    end

    test "a start tightens a key and folder an older version left open", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "sessions"))
      key = Path.join(dir, "secret.key")
      File.write!(key, Base.encode64(:crypto.strong_rand_bytes(64)))
      session = Path.join([dir, "sessions", "old.session"])
      File.write!(session, :erlang.term_to_binary(%{id: "old"}))
      File.chmod!(dir, 0o755)
      File.chmod!(key, 0o644)
      File.chmod!(Path.join(dir, "sessions"), 0o755)
      File.chmod!(session, 0o644)

      kept = File.read!(key)
      assert Web.stable_key_base() == kept

      assert mode(dir) == 0o700
      assert mode(key) == 0o600
      assert mode(Path.join(dir, "sessions")) == 0o700
      assert mode(session) == 0o600
    end
  end

  describe "token and settings" do
    test "an open token file is closed on write", %{tmp_dir: tmp} do
      path = Path.join(tmp, "token")
      File.write!(path, "old")
      File.chmod!(path, 0o644)

      Web.persist_token("secret", path)

      assert mode(path) == 0o600
      assert File.read!(path) == "secret"
    end

    test "an open settings file is closed on save", %{tmp_dir: tmp} do
      path = Path.join(tmp, "settings.json")
      File.write!(path, "{}")
      File.chmod!(path, 0o644)
      previous = Application.get_env(:ex_athena, :settings_path)
      Application.put_env(:ex_athena, :settings_path, path)

      on_exit(fn ->
        Application.put_env(:ex_athena, :settings_path, previous)
        Application.delete_env(:ex_athena, :loop)
      end)

      ExAthena.Web.Settings.save(%{"loop.max_iterations" => "7"})

      assert mode(path) == 0o600
    end
  end

  describe "saved sessions" do
    test "the folder is 0700 and a saved session 0600", %{dir: dir} do
      Sessions.save(%{id: "abc", title: "t"})

      assert mode(Path.join(dir, "sessions")) == 0o700
      assert mode(Path.join([dir, "sessions", "abc.session"])) == 0o600
      assert {:ok, %{id: "abc"}} = Sessions.load("abc")
    end

    test "saving over an open file closes it", %{dir: dir} do
      Sessions.save(%{id: "abc"})
      file = Path.join([dir, "sessions", "abc.session"])
      File.chmod!(file, 0o644)

      Sessions.save(%{id: "abc", title: "again"})

      assert mode(file) == 0o600
    end

    test "the recent-projects list is 0600", %{dir: dir, tmp_dir: tmp} do
      :ok = Sessions.touch_recent(tmp)

      assert mode(Path.join(dir, "recent.json")) == 0o600
      assert mode(dir) == 0o700
    end
  end
end
