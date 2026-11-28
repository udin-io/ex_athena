defmodule Mix.Tasks.Athena.Trace do
  @shortdoc "Save a web chat session's trace as one HTML file"

  @moduledoc """
  Writes the Trace tab's picture of a saved web chat session to one HTML file
  that opens in any browser with no server (issue 353). The Trace tab's Save
  button writes the same file.

  ## Usage

      mix athena.trace d745ba277793
      mix athena.trace d745ba277793 --out /tmp/run.html

  The session id is the one in the chat's address (`/c/<id>`). The file goes
  to `trace-<id>.html` in the current folder unless `--out` names another.

  The file leaves out file contents, cuts any output past its first 2,000
  characters, and replaces every configured key and token with `[redacted]`
  (see `ExAthena.Web.TraceExport`), and it says so at its top.
  """

  use Mix.Task

  alias ExAthena.Web.{Sessions, Trace, TraceExport}

  @id ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @impl Mix.Task
  def run(argv) do
    # Starts the provider registry, so keys in provider files are redacted too.
    Mix.Task.run("app.start", [])

    {opts, args, invalid} = OptionParser.parse(argv, strict: [out: :string])

    if invalid != [], do: Mix.raise("unknown option: #{inspect(invalid)}")

    id =
      case args do
        [id] -> id
        _ -> Mix.raise("usage: mix athena.trace <session id> [--out FILE]")
      end

    unless Regex.match?(@id, id), do: Mix.raise("#{inspect(id)} is not a session id")

    session =
      case Sessions.load(id) do
        {:ok, session} -> session
        {:error, _} -> Mix.raise(~s(no saved session "#{id}" in #{Sessions.base_dir()}))
      end

    out = Path.expand(opts[:out] || TraceExport.file_name(session))
    html = TraceExport.html(session, Trace.helper_records(session))

    File.mkdir_p!(Path.dirname(out))
    write_private(out, html)
    Mix.shell().info("Wrote #{out}")
  end

  # Written to a new file of our own, then renamed over the target: a rename
  # replaces a link planted at `out` instead of following it, and the file is
  # owner-only before any byte goes in. A failure removes the new file.
  defp write_private(out, html) do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    tmp = Path.join(Path.dirname(out), ".trace-#{suffix}.tmp")

    with {:ok, file} <- File.open(tmp, [:write, :exclusive, :binary]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- IO.binwrite(file, html),
         :ok <- File.close(file),
         :ok <- File.rename(tmp, out) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        Mix.raise("could not write #{out}: #{:file.format_error(reason)}")
    end
  end
end
