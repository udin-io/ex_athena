defmodule ExAthena.Web.Files do
  @moduledoc """
  Pure filesystem helpers for the web UI file browser.

  Both functions take an absolute `root` directory and a path that is
  either absolute or relative to it, and refuse to touch anything outside
  the root:

    * `list_dir/2` — directory listing with artifact dirs (`_build/`,
      `deps/`, `node_modules/`, … per `ExAthena.Permissions.artifact_dirs/0`)
      filtered out, directories first, case-insensitive alphabetical order
      within each group.
    * `read_file/2` — file contents capped at 2MB (the same
      context-protection budget as `ExAthena.Tools.Read`); files containing
      NUL bytes are reported as binary with empty content.

  No state, no processes — safe to call from LiveView events.
  """

  # Same context-protection budget as `ExAthena.Tools.Read`.
  @read_cap 2_000_000

  alias ExAthena.Permissions
  alias ExAthena.ToolContext

  @spec list_dir(String.t() | nil, String.t()) ::
          {:ok, [%{name: String.t(), path: String.t(), is_dir: boolean()}]}
          | {:error, :no_root | :outside_root | :no_such_directory | :not_a_directory}
  def list_dir(root, dir_path) do
    with {:ok, dir} <- resolve(root, dir_path) do
      case File.stat(dir) do
        {:error, :enoent} ->
          {:error, :no_such_directory}

        {:ok, %File.Stat{type: :directory}} ->
          list_entries(dir)

        {:ok, _other} ->
          {:error, :not_a_directory}
      end
    end
  end

  @spec read_file(String.t() | nil, String.t()) ::
          {:ok,
           %{
             path: String.t(),
             content: String.t(),
             size: non_neg_integer(),
             truncated: boolean(),
             binary: boolean()
           }}
          | {:error, :no_root | :outside_root | :no_such_file | :not_a_file}
  def read_file(root, file_path) do
    with {:ok, path} <- resolve(root, file_path) do
      case File.stat(path) do
        {:error, :enoent} ->
          {:error, :no_such_file}

        {:ok, %File.Stat{type: :regular}} ->
          read_content(path)

        {:ok, _other} ->
          {:error, :not_a_file}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp list_entries(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        entries =
          names
          |> Enum.map(fn name ->
            full = Path.join(dir, name)
            %{name: name, path: full, is_dir: dir?(File.stat(full))}
          end)
          |> Enum.reject(&artifact_dir?/1)

        {:ok,
         entries
         |> Enum.sort_by(fn entry -> {not entry.is_dir, String.downcase(entry.name)} end)}

      {:error, :enoent} ->
        {:error, :no_such_directory}

      {:error, :enotdir} ->
        {:error, :not_a_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dir?({:ok, %File.Stat{type: :directory}}), do: true
  defp dir?(_), do: false

  # Artifact dirs per `ExAthena.Permissions.artifact_dirs/0` — entries end in
  # `/` so a same-named *file* is never filtered, only a directory.
  defp artifact_dir?(%{is_dir: true, name: name}) do
    Enum.any?(Permissions.artifact_dirs(), fn dir ->
      String.starts_with?(name <> "/", dir)
    end)
  end

  defp artifact_dir?(_), do: false

  defp read_content(path) do
    size = File.stat!(path).size

    case File.open(path, [:read_binary]) do
      {:ok, io} ->
        chunk =
          case IO.binread(io, @read_cap) do
            :eof -> ""
            bin when is_binary(bin) -> bin
          end

        File.close(io)

        # NUL byte (or invalid UTF-8) marks the file as binary; the UI
        # renders a placeholder instead of dumping raw bytes.
        binary? = String.contains?(chunk, <<0>>) or not String.valid?(chunk)

        {:ok,
         %{
           path: path,
           content: if(binary?, do: "", else: chunk),
           size: size,
           truncated: size > @read_cap,
           binary: binary?
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Normalize `dir_path` against `root` and verify the result stays inside it.
  # `root == nil` -> `:no_root`; escape attempts -> `:outside_root`.
  #
  # Confinement goes through `ExAthena.ToolContext.within_roots?/2` — the same
  # guard the file tools use — rather than a string prefix test. A prefix test
  # only rejects lexical `../` traversal: it compares the path as written, so a
  # symlink INSIDE the root pointing out of it (`root/link -> /etc`) reads as
  # inside, and `File.stat`/`File.open` then follow it. `within_roots?/2`
  # canonicalizes every symlink component before comparing, and compares on
  # path segments, so an escaping link is refused while links that stay inside
  # (and a root that is itself a symlink, e.g. macOS `/tmp` -> `/private/tmp`)
  # keep working.
  defp resolve(nil, _dir_path), do: {:error, :no_root}

  defp resolve(root, dir_path) when is_binary(root) and is_binary(dir_path) do
    # A NUL byte would raise ArgumentError out of the :file calls below rather
    # than returning an error tuple, crashing the LiveView. Paths arrive
    # straight from client `phx-value-path`, so reject it here.
    if String.contains?(dir_path, <<0>>) do
      {:error, :outside_root}
    else
      candidate = Path.absname(Path.expand(dir_path, Path.expand(root)))

      if ToolContext.within_roots?(candidate, [root]) do
        {:ok, candidate}
      else
        {:error, :outside_root}
      end
    end
  end

  defp resolve(_root, _dir_path), do: {:error, :no_root}
end
