defmodule ExAthena.Mcp.ConfigTest do
  use ExUnit.Case, async: true

  alias ExAthena.Mcp.Config
  alias ExAthena.Mcp.Config.Server

  describe "load/1" do
    test "valid local entry returns Server struct" do
      raw = %{
        "fetch" => %{type: :local, command: ["uvx", "mcp-server-fetch"], enabled: true}
      }

      assert {:ok, [server]} = Config.load(raw)
      assert %Server{} = server
      assert server.name == "fetch"
      assert server.type == :local
      assert server.command == "uvx"
      assert server.args == ["mcp-server-fetch"]
      assert server.enabled == true
    end

    test "valid remote entry returns Server struct" do
      raw = %{
        "github" => %{
          type: :remote,
          url: "https://api.example.com/mcp",
          headers: %{"Authorization" => "Bearer tok"},
          enabled: true
        }
      }

      assert {:ok, [server]} = Config.load(raw)
      assert server.name == "github"
      assert server.type == :remote
      assert server.url == "https://api.example.com/mcp"
      assert server.headers == %{"Authorization" => "Bearer tok"}
    end

    test "normalizes string type value" do
      raw = %{"s" => %{"type" => "local", "command" => ["echo"], "enabled" => true}}

      assert {:ok, [server]} = Config.load(raw)
      assert server.type == :local
    end

    test "normalizes string keys" do
      raw = %{
        "s" => %{
          "type" => "remote",
          "url" => "https://example.com/mcp",
          "enabled" => true
        }
      }

      assert {:ok, [server]} = Config.load(raw)
      assert server.type == :remote
      assert server.url == "https://example.com/mcp"
    end

    test "normalizes environment key to env field" do
      raw = %{
        "s" => %{
          type: :local,
          command: ["echo"],
          environment: %{"FOO" => "bar"},
          enabled: true
        }
      }

      assert {:ok, [server]} = Config.load(raw)
      assert server.env == %{"FOO" => "bar"}
    end

    test "defaults env to empty map when not provided" do
      raw = %{"s" => %{type: :local, command: ["echo"], enabled: true}}

      assert {:ok, [server]} = Config.load(raw)
      assert server.env == %{}
    end

    test "splits command list: head is command, tail is args" do
      raw = %{
        "s" => %{type: :local, command: ["elixir", "script.exs", "--verbose"], enabled: true}
      }

      assert {:ok, [server]} = Config.load(raw)
      assert server.command == "elixir"
      assert server.args == ["script.exs", "--verbose"]
    end

    test "disabled entry is included in results with enabled: false" do
      raw = %{"s" => %{type: :local, command: ["echo"], enabled: false}}

      assert {:ok, [server]} = Config.load(raw)
      assert server.enabled == false
    end

    test "empty config returns empty list" do
      assert {:ok, []} = Config.load(%{})
    end

    test "nil config returns empty list" do
      assert {:ok, []} = Config.load(nil)
    end

    test "returns error for local without command" do
      raw = %{"s" => %{type: :local, enabled: true}}

      assert {:error, error} = Config.load(raw)
      assert error.kind == :bad_request
    end

    test "returns error for local with empty command list" do
      raw = %{"s" => %{type: :local, command: [], enabled: true}}

      assert {:error, error} = Config.load(raw)
      assert error.kind == :bad_request
    end

    test "returns error for remote without url" do
      raw = %{"s" => %{type: :remote, enabled: true}}

      assert {:error, error} = Config.load(raw)
      assert error.kind == :bad_request
    end

    test "returns error for unknown type" do
      raw = %{"s" => %{type: :ftp, url: "ftp://example.com", enabled: true}}

      assert {:error, _} = Config.load(raw)
    end

    test "multiple entries returned in order" do
      raw = %{
        "a" => %{type: :local, command: ["cmd1"], enabled: true},
        "b" => %{type: :local, command: ["cmd2"], enabled: true}
      }

      assert {:ok, servers} = Config.load(raw)
      assert length(servers) == 2
      names = Enum.map(servers, & &1.name) |> Enum.sort()
      assert names == ["a", "b"]
    end
  end

  describe "to_client_opts/1" do
    test "local server returns command, args, env" do
      server = %Server{
        name: "s",
        type: :local,
        command: "elixir",
        args: ["script.exs"],
        env: %{"FOO" => "bar"},
        enabled: true
      }

      opts = Config.to_client_opts(server)
      assert opts[:command] == "elixir"
      assert opts[:args] == ["script.exs"]
      assert opts[:env] == %{"FOO" => "bar"}
    end

    test "remote server returns url and headers" do
      server = %Server{
        name: "s",
        type: :remote,
        url: "https://example.com/mcp",
        headers: %{"X-Key" => "val"},
        enabled: true
      }

      opts = Config.to_client_opts(server)
      assert opts[:url] == "https://example.com/mcp"
      assert opts[:headers] == %{"X-Key" => "val"}
    end
  end
end
