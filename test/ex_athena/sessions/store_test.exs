defmodule ExAthena.Sessions.StoreTest do
  use ExUnit.Case, async: false

  alias ExAthena.Sessions.Store
  alias ExAthena.Sessions.Stores.{InMemory, Jsonl}

  describe "Store.new_event/2" do
    test "stamps a uuid + iso8601 ts" do
      event = Store.new_event(:user_message, %{message: "hi"})

      assert event.event == :user_message
      assert event.data == %{message: "hi"}
      assert byte_size(event.uuid) >= 8
      assert {:ok, _, 0} = DateTime.from_iso8601(event.ts)
    end
  end

  describe "InMemory" do
    setup do
      InMemory.reset()
      :ok
    end

    test "append + read returns events in append order" do
      e1 = Store.new_event(:user_message, %{message: "first"})
      e2 = Store.new_event(:assistant_message, %{message: "ok"})

      :ok = InMemory.append("sess-1", e1)
      :ok = InMemory.append("sess-1", e2)

      assert {:ok, [^e1, ^e2]} = InMemory.read("sess-1")
    end

    test "tail/2 returns the last N events" do
      Enum.each(1..5, fn i ->
        InMemory.append("sess-1", Store.new_event(:user_message, %{i: i}))
      end)

      assert {:ok, events} = InMemory.tail("sess-1", 2)
      assert length(events) == 2
      assert hd(events).data.i == 4
    end

    test "list/0 enumerates session ids" do
      InMemory.append("a", Store.new_event(:session_start, %{}))
      InMemory.append("b", Store.new_event(:session_start, %{}))

      sids = InMemory.list()
      assert "a" in sids
      assert "b" in sids
    end
  end

  describe "Jsonl" do
    setup do
      root = Path.join(System.tmp_dir!(), "jsonl_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      # Stop any running instance, restart with the test root.
      case GenServer.whereis(Jsonl) do
        nil -> :ok
        pid -> :ok = GenServer.stop(pid, :normal, 1_000)
      end

      {:ok, _} = Jsonl.start_link(root: root, flush_interval_ms: 50_000)

      on_exit(fn ->
        case GenServer.whereis(Jsonl) do
          nil -> :ok
          pid -> :ok = GenServer.stop(pid, :normal, 1_000)
        end

        File.rm_rf!(root)
      end)

      {:ok, root: root}
    end

    test "buffered events flush to JSONL on demand", %{root: root} do
      e1 = Store.new_event(:user_message, %{message: "hello"})
      e2 = Store.new_event(:assistant_message, %{message: "world"})

      :ok = Jsonl.append("sess-1", e1)
      :ok = Jsonl.append("sess-1", e2)

      :ok = Jsonl.flush()

      path = Path.join(root, "sess-1.jsonl")
      assert File.exists?(path)

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2
    end

    test "read/1 returns events even if some are still buffered", %{root: _root} do
      :ok = Jsonl.append("sess-X", Store.new_event(:user_message, %{message: "foo"}))

      assert {:ok, events} = Jsonl.read("sess-X")
      assert [%{event: :user_message, data: %{message: "foo"}}] = events
    end

    test "list/0 enumerates session JSONL files", %{root: _root} do
      :ok = Jsonl.append("alpha", Store.new_event(:session_start, %{}))
      :ok = Jsonl.append("beta", Store.new_event(:session_start, %{}))
      :ok = Jsonl.flush()

      sids = Jsonl.list()
      assert "alpha" in sids
      assert "beta" in sids
    end
  end
end
