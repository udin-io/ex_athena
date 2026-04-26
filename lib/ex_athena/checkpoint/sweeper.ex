defmodule ExAthena.Checkpoint.Sweeper do
  @moduledoc """
  One-shot startup task that GCs file-history directories older than
  30 days. Runs alongside the `Agents.WorktreeSweeper`.

  Started under the application supervisor; runs once at boot and
  exits. Best-effort — failures are logged at info-level and don't
  prevent the application from starting.
  """

  require Logger

  @max_age_seconds 30 * 24 * 60 * 60
  @history_subdir ".exathena/file-history"

  @doc false
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [__MODULE__, :run, []]},
      restart: :transient,
      type: :worker
    }
  end

  @spec run() :: :ok
  def run do
    cwd = File.cwd!()
    history_root = Path.join(cwd, @history_subdir)

    case File.ls(history_root) do
      {:ok, sessions} ->
        Enum.each(sessions, fn sid -> maybe_remove(Path.join(history_root, sid)) end)

      {:error, _} ->
        :ok
    end

    :ok
  rescue
    e ->
      Logger.info("Checkpoint.Sweeper failed: #{Exception.message(e)}")
      :ok
  end

  defp maybe_remove(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        if age_seconds(mtime) > @max_age_seconds do
          File.rm_rf(path)
          :ok
        end

      _ ->
        :ok
    end
  end

  defp age_seconds(mtime) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    mtime_unix = :calendar.datetime_to_gregorian_seconds(mtime)
    epoch_offset = :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
    now - (mtime_unix - epoch_offset)
  end
end
