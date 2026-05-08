defmodule ExAthena.Mcp.Config do
  @moduledoc """
  Loads and validates MCP server configuration.

  Reads from `Application.get_env(:ex_athena, :mcp_servers, %{})`. The raw
  config mirrors OpenCode's JSONC shape — string or atom keys, `"local"` or
  `:local` for type — so udin_code can map its JSONC directly.

  ## Example

      config :ex_athena, :mcp_servers, %{
        "fetch" => %{
          type: :local,
          command: ["uvx", "mcp-server-fetch"],
          environment: %{"FOO" => "bar"},
          enabled: true
        },
        "github" => %{
          type: :remote,
          url: "https://api.example.com/mcp",
          headers: %{"Authorization" => "Bearer …"},
          enabled: true
        }
      }
  """

  alias ExAthena.Error

  defmodule Server do
    @moduledoc "Validated MCP server configuration entry."

    @enforce_keys [:name, :type, :enabled]
    defstruct [:name, :type, :command, :args, :env, :url, :headers, :enabled]

    @type t :: %__MODULE__{
            name: String.t(),
            type: :local | :remote,
            command: String.t() | nil,
            args: [String.t()],
            env: %{String.t() => String.t()},
            url: String.t() | nil,
            headers: %{String.t() => String.t()},
            enabled: boolean()
          }
  end

  @schema NimbleOptions.new!(
            type: [type: {:in, [:local, :remote]}, required: true],
            command: [type: {:list, :string}],
            # :any allows string-keyed maps from OpenCode JSONC config
            environment: [type: :any, default: %{}],
            url: [type: :string],
            headers: [type: :any, default: %{}],
            enabled: [type: :boolean, default: true]
          )

  @string_key_map %{
    "type" => :type,
    "command" => :command,
    "environment" => :environment,
    "url" => :url,
    "headers" => :headers,
    "enabled" => :enabled,
    "args" => :args
  }

  @doc """
  Load server configs from `raw` (defaults to `Application.get_env(:ex_athena, :mcp_servers, %{})`).

  Returns `{:ok, [%Server{}]}` or `{:error, %ExAthena.Error{}}`.
  """
  @spec load(map() | nil) :: {:ok, [Server.t()]} | {:error, Error.t()}
  def load(raw \\ Application.get_env(:ex_athena, :mcp_servers, %{}))

  def load(nil), do: {:ok, []}
  def load(%{} = raw) when map_size(raw) == 0, do: {:ok, []}

  def load(%{} = raw) do
    raw
    |> Enum.reduce_while({:ok, []}, fn {name, entry}, {:ok, acc} ->
      case validate_entry(name, entry) do
        {:ok, server} -> {:cont, {:ok, [server | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, servers} -> {:ok, Enum.reverse(servers)}
      err -> err
    end
  end

  @doc "Convert a `%Server{}` to keyword opts suitable for `ExAthena.Mcp.Client.start_link/1`."
  @spec to_client_opts(Server.t()) :: keyword()
  def to_client_opts(%Server{type: :local} = server) do
    [command: server.command, args: server.args || [], env: server.env || %{}]
  end

  def to_client_opts(%Server{type: :remote} = server) do
    [url: server.url, headers: server.headers || %{}]
  end

  # ── Private ────────────────────────────────────────────────────────

  defp validate_entry(name, entry) when is_map(entry) do
    case normalize_entry(entry) do
      {:ok, normalized} ->
        case NimbleOptions.validate(normalized, @schema) do
          {:ok, valid} ->
            case type_specific_check(valid) do
              :ok -> {:ok, build_server(name, valid)}
              {:error, msg} -> {:error, Error.new(:bad_request, "MCP server '#{name}': #{msg}")}
            end

          {:error, e} ->
            {:error, Error.new(:bad_request, "MCP server '#{name}': #{Exception.message(e)}")}
        end

      {:error, msg} ->
        {:error, Error.new(:bad_request, "MCP server '#{name}': #{msg}")}
    end
  end

  defp normalize_entry(entry) do
    entry
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      case normalize_key(k) do
        {:ok, key} ->
          {:cont, {:ok, [{key, normalize_value(k, v)} | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, kvs} -> {:ok, kvs |> Map.new() |> Map.to_list()}
      {:error, _} = err -> err
    end
  end

  defp normalize_key(k) when is_binary(k) do
    case Map.fetch(@string_key_map, k) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        try do
          {:ok, String.to_existing_atom(k)}
        rescue
          ArgumentError -> {:error, "unknown config key #{inspect(k)}"}
        end
    end
  end

  defp normalize_key(k) when is_atom(k), do: {:ok, k}

  # Normalize string type values to atoms so NimbleOptions `{:in, ...}` check passes
  defp normalize_value(:type, "local"), do: :local
  defp normalize_value(:type, "remote"), do: :remote
  defp normalize_value("type", "local"), do: :local
  defp normalize_value("type", "remote"), do: :remote
  defp normalize_value(_k, v), do: v

  defp type_specific_check(opts) do
    case Keyword.get(opts, :type) do
      :local ->
        cmd = Keyword.get(opts, :command, [])

        if is_list(cmd) and cmd != [] do
          :ok
        else
          {:error, "type :local requires a non-empty :command list"}
        end

      :remote ->
        if Keyword.get(opts, :url) do
          :ok
        else
          {:error, "type :remote requires a :url"}
        end
    end
  end

  defp build_server(name, opts) do
    cmd_list = Keyword.get(opts, :command, [])

    %Server{
      name: to_string(name),
      type: Keyword.fetch!(opts, :type),
      command: List.first(cmd_list),
      args: Enum.drop(cmd_list, 1),
      env: Keyword.get(opts, :environment, %{}),
      url: Keyword.get(opts, :url),
      headers: Keyword.get(opts, :headers, %{}),
      enabled: Keyword.get(opts, :enabled, true)
    }
  end
end
