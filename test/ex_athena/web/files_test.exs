defmodule ExAthena.Web.FilesTest do
  use ExUnit.Case, async: true

  alias ExAthena.Web.Files

  @cap 2_000_000
  @big_size 3_000_000

  # ExUnit's own per-test temp dir. Hand-building one from `System.tmp_dir!/0`
  # yielded a doubled separator on macOS (`/T//ex_athena_…`), which the
  # assertions then compared against paths that `Path.expand` had normalised.
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    parent = tmp_dir
    root = Path.join(parent, "root")

    File.mkdir_p!(Path.join(root, "subdir"))
    File.mkdir_p!(Path.join(root, "node_modules"))
    File.write!(Path.join(root, "subdir/inner.txt"), "inner file")
    File.write!(Path.join(root, "a.txt"), "hello a")
    File.write!(Path.join(root, "B.txt"), "hello B")
    File.write!(Path.join(root, "big.bin"), String.duplicate("x", @big_size))
    File.write!(Path.join(root, "data.bin"), <<0, 1, 2>>)
    File.write!(Path.join(parent, "secret.txt"), "top secret")

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

  # A prefix-based confinement check passes a symlink that is lexically inside
  # the root, and `File.stat`/`File.open` then follow it out. Proven against
  # the original implementation: `read_file` returned the outside file's
  # contents. Both entry points are covered — listing a directory through the
  # link leaks filenames even when no file is read.
  test "refuses a symlink inside the root that points outside it", %{root: root, parent: parent} do
    File.ln_s!(parent, Path.join(root, "escape"))

    assert {:error, :outside_root} = Files.list_dir(root, Path.join(root, "escape"))
    assert {:error, :outside_root} = Files.read_file(root, Path.join(root, "escape/secret.txt"))
  end

  # The guard must not over-reject: a link that stays inside the root is a
  # normal thing to have in a project and still resolves.
  test "follows a symlink that stays inside the root", %{root: root} do
    File.ln_s!(Path.join(root, "subdir"), Path.join(root, "inside_link"))

    assert {:ok, %{content: "inner file"}} =
             Files.read_file(root, Path.join(root, "inside_link/inner.txt"))
  end

  # Paths arrive from client `phx-value-path`. A NUL byte raises ArgumentError
  # out of the :file calls instead of returning an error tuple, which would
  # crash the LiveView rather than show an error.
  test "rejects a path containing a NUL byte instead of crashing", %{root: root} do
    assert {:error, :outside_root} = Files.list_dir(root, Path.join(root, "sub\0dir"))
    assert {:error, :outside_root} = Files.read_file(root, Path.join(root, "a\0.txt"))
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
