defmodule ExAthena.Tools.FinishTest do
  use ExUnit.Case, async: true

  alias ExAthena.Tools.Finish

  describe "Tool behaviour" do
    test "name/0 returns finish" do
      assert Finish.name() == "finish"
    end

    test "description/0 is non-empty" do
      assert is_binary(Finish.description())
      assert byte_size(Finish.description()) > 0
    end

    test "schema/0 is a valid JSON schema object with optional fields" do
      schema = Finish.schema()
      assert schema.type == "object"

      assert Map.has_key?(schema.properties, :summary) or
               Map.has_key?(schema.properties, "summary")

      assert Map.has_key?(schema.properties, :deliverable) or
               Map.has_key?(schema.properties, "deliverable")

      assert schema.required == [] or schema[:required] == []
    end

    test "parallel_safe?/0 returns false" do
      refute Finish.parallel_safe?()
    end
  end

  # The third element is the ARGUMENT the payload came from, and it decides
  # whether the parent reads the payload verbatim (issue 263). `deliverable` is
  # "the primary output"; `summary` is "a brief description of what was
  # accomplished", which is the shape issue 251 was about.
  describe "execute/2" do
    test "tags a deliverable argument as :deliverable" do
      assert {:halt, {:submitted, "my plan", :deliverable}} =
               Finish.execute(%{"deliverable" => "my plan"}, %{})
    end

    test "accepts summary as the payload, tagged :summary" do
      assert {:halt, {:submitted, "task done", :summary}} =
               Finish.execute(%{"summary" => "task done"}, %{})
    end

    test "prefers deliverable over summary when both present" do
      assert {:halt, {:submitted, "the deliverable", :deliverable}} =
               Finish.execute(%{"deliverable" => "the deliverable", "summary" => "ignored"}, %{})
    end

    test "a blank deliverable falls through to summary" do
      assert {:halt, {:submitted, "task done", :summary}} =
               Finish.execute(%{"deliverable" => "   ", "summary" => "task done"}, %{})
    end

    test "returns no payload and no source when no args given" do
      assert {:halt, {:submitted, nil, :none}} = Finish.execute(%{}, %{})
    end
  end
end
