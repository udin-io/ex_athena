defmodule ExAthena.Loop.SchemaValidationTest do
  @moduledoc """
  Acceptance tests for schema-validation and provider-auth error routing.
  Drives the full Loop.run/2 pipeline via the Mock provider.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Error, Loop}

  setup do
    dir = Path.join(System.tmp_dir!(), "schema_validation_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "malformed tool-call text routes to :error_schema_validation with diagnostic", %{dir: dir} do
    # The mock returns text that looks like a tool call but is malformed JSON — causes
    # ToolCalls.extract to fail, which should be classified as :error_schema_validation.
    assert {:ok, result} =
             Loop.run("do something",
               provider: :mock,
               mock: [text: "~~~tool_call\n{invalid json\n~~~"],
               cwd: dir,
               tools: []
             )

    assert result.finish_reason == :error_schema_validation
    assert is_map(result.error_diagnostic)
    assert is_list(result.error_diagnostic.violations)
    assert result.error_diagnostic.violations != []
    assert result.error_diagnostic.received == "~~~tool_call\n{invalid json\n~~~"
  end

  test "generic provider error routes to :error_during_execution with nil diagnostic", %{dir: dir} do
    assert {:ok, result} =
             Loop.run("do something",
               provider: :mock,
               mock: [error: :boom],
               cwd: dir,
               tools: []
             )

    assert result.finish_reason == :error_during_execution
    assert result.error_diagnostic == nil
  end

  test "provider auth error (:unauthorized) routes to :error_provider_auth with nil diagnostic",
       %{dir: dir} do
    assert {:ok, result} =
             Loop.run("do something",
               provider: :mock,
               mock: [error: %Error{kind: :unauthorized, message: "invalid api key"}],
               cwd: dir,
               tools: []
             )

    assert result.finish_reason == :error_provider_auth
    assert result.error_diagnostic == nil
  end
end
