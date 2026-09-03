defmodule ExAthena.Tools.TodoWriteTest do
  @moduledoc """
  Rejections have to teach the model what to send instead.

  Every invalid call returned a bare atom — `:missing_todos`,
  `:invalid_status` — naming neither the valid values nor which item was
  wrong. A small model reads that and repeats the identical call; both were
  seen costing a live run an iteration apiece.
  """
  use ExUnit.Case, async: true

  alias ExAthena.ToolContext
  alias ExAthena.Tools.TodoWrite

  defp ctx, do: ToolContext.new(cwd: "/tmp")

  defp todo(content, status), do: %{"content" => content, "status" => status}

  describe "valid input" do
    test "renders the list back with status markers" do
      todos = [todo("explore", "completed"), todo("write it up", "in_progress")]

      assert {:ok, text} = TodoWrite.execute(%{"todos" => todos}, ctx())
      assert text =~ "[x] explore"
      assert text =~ "[~] write it up"
    end

    test "an empty list is a valid list" do
      assert {:ok, _} = TodoWrite.execute(%{"todos" => []}, ctx())
    end
  end

  describe "rejections name the problem" do
    test "a missing todos key says what the argument is called" do
      assert {:error, message} = TodoWrite.execute(%{}, ctx())
      assert message =~ "todos"
      assert message =~ "list"
    end

    test "an unrecognised status names the offending item and the valid values" do
      todos = [todo("explore", "completed"), todo("write it up", "in-progress")]

      assert {:error, message} = TodoWrite.execute(%{"todos" => todos}, ctx())
      assert message =~ "in-progress"
      assert message =~ "write it up"
      assert message =~ "pending"
      assert message =~ "in_progress"
      assert message =~ "completed"
    end

    test "a missing status is reported as such, not as an unknown one" do
      assert {:error, message} = TodoWrite.execute(%{"todos" => [%{"content" => "x"}]}, ctx())
      assert message =~ "status"
      assert message =~ "\"x\""
    end

    test "a non-string content names the item's position" do
      todos = [todo("fine", "pending"), %{"content" => 42, "status" => "pending"}]

      assert {:error, message} = TodoWrite.execute(%{"todos" => todos}, ctx())
      assert message =~ "content"
      assert message =~ "2"
    end

    test "a todo that is not an object at all names its position" do
      assert {:error, message} = TodoWrite.execute(%{"todos" => ["just a string"]}, ctx())
      assert message =~ "1"
      assert message =~ "object"
    end
  end
end
