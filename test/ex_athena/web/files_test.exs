defmodule ExAthena.Web.FilesTest do
  use ExUnit.Case, async: true

  alias ExAthena.Web.Files

  @cap 2_000_000
  @big_size 3_000_000

  setup do
    # `File.mkdtemp!/1` is unavailable in this Elixir build; build a unique
    # temp dir from `System.tmp_dir!/0` + a unique integer instead.
    parent =
      System.tmp_dir!() <> "/ex_athena_files_parent_" <>
        Integer.to_string(:erlang.unique_integer([:positive]))

    File.mkdir_p!(parent)
    root = Path.join(parent, "root")

    File.mkdir_p!(Path.join(root, "subdir"))
    File.mkdir_p!(Path.join(root, "node_modules"))
    File.write!(Path.join(root, "subdir/inner.txt"), "inner file")
    File.write!(Path.join(root, "a.txt"), "hello a")
    File.write!(Path.join(root, "B.txt"), "hello B")
    File.write!(Path.join(root, "big.bin"), String.duplicate("x", @big_size))
    File.write!(Path.join(root, "data.bin"), <<0, 1, 2>>)
    File.write!(Path.join(parent, "secret.txt"), "top secret")

    on_exit(fn -> File.rm_rf!(parent) end)

    %{root: root, parent: parent}
  end

  test "lists directories first, case-insensitively, excluding artifact dirs", %{root: root} do
    subdir_path = Path.join(root, "subdir")

    assert {:ok, entries} = Files.list_dir(root, ".")

    assert ["subdir", "a.txt", "B.txt", "big.bin", "data.bin"] =
             Enum.map(entries, & &1.name)

    assert [%{name: "subdir", path: ^subdir_path, is_dir: true}] =
             Enum.filter(entries, & &1.is_dir)
  end

  test "lists a subdirectory", %{root: root} do
    inner_path = Path.join(root, "subdir/inner.txt")

    assert {:ok, [%{name: "inner.txt", path: ^inner_path, is_dir: false}]} =
             Files.list_dir(root, "subdir")
  end

  test "rejects missing directories", %{root: root} do
    assert {:error, :no_such_directory} = Files.list_dir(root, "missing")
  end

  test "rejects a nil root" do
    assert {:error, :no_root} = Files.list_dir(nil, "x")
    assert {:error, :no_root} = Files.read_file(nil, "x")
  end

  test "rejects paths outside the root", %{root: root} do
    assert {:error, :outside_root} = Files.list_dir(root, "../..")
    assert {:error, :outside_root} = Files.read_file(root, "../secret.txt")
  end

  test "reads a small text file in full", %{root: root} do
    assert {:ok, file} = Files.read_file(root, "a.txt")

    assert file.path == Path.join(root, "a.txt")
    assert file.content == "hello a"
    assert file.size == byte_size("hello a")
    assert file.truncated == false
    assert file.binary == false
  end

  test "caps large files at 2MB", %{root: root} do
    assert {:ok, file} = Files.read_file(root, "big.bin")

    assert file.truncated == true
    assert file.binary == false
    assert byte_size(file.content) == @cap
    assert file.content == String.duplicate("x", @cap)
    assert file.size == @big_size
  end

  test "flags binary files and returns empty content", %{root: root} do
    assert {:ok, file} = Files.read_file(root, "data.bin")

    assert file.binary == true
    assert file.content == ""
    assert file.size == 3
    assert file.truncated == false
  end

  test "rejects non-directories for list_dir", %{root: root} do
    assert {:error, :not_a_directory} = Files.list_dir(root, "a.txt")
  end

  test "rejects non-files for read_file", %{root: root} do
    assert {:error, :not_a_file} = Files.read_file(root, "subdir")
    assert {:error, :no_such_file} = Files.read_file(root, "missing.txt")
  end
end
