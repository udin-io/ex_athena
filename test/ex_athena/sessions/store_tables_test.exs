defmodule ExAthena.Sessions.StoreTablesTest do
  @moduledoc """
  A store's tables belong to the store's own process, never to whichever
  process happened to call it first (issue 149).
  """
  use ExUnit.Case, async: false

  alias ExAthena.Sessions.Stores.{ETS, InMemory}

  for {store, table, call} <- [
        {ETS, :ex_athena_session_rows, :list_sessions},
        {InMemory, ExAthena.Sessions.Stores.InMemory, :list}
      ] do
    test "#{inspect(store)}: a call from a short-lived process leaves the table with the store" do
      store = unquote(store)
      table = unquote(table)
      pid = Process.whereis(store)
      assert is_pid(pid)

      # Drop the tables under the running store, as a crash of a caller that
      # had created them used to.
      :ets.delete(table)

      call = unquote(call)
      task = Task.async(fn -> apply(store, call, []) end)
      Task.await(task)

      assert :ets.info(table, :owner) == pid
    end
  end
end
