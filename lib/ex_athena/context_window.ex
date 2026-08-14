defmodule ExAthena.ContextWindow do
  @moduledoc false

  use GenServer

  @table :ex_athena_context_window_cache
  @timeout_ms 3_000

  @ollama_default "http://localhost:11434"
  @llamacpp_default "http://localhost:8080"
  @exo_default "http://localhost:52415"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec lookup(keyword()) :: {:ok, pos_integer()} | :error
  def lookup(opts) do
    with backend when backend in [:ollama, :llamacpp, :exo] <-
           Keyword.get(opts, :openai_compatible_backend),
         model_raw when is_binary(model_raw) and model_raw != "" <-
           Keyword.get(opts, :model) do
      model = strip_provider_prefix(model_raw, Keyword.get(opts, :req_llm_provider_tag))
      base_url = resolve_base_url(opts, backend)
      key = {backend, base_url, model}

      case ets_lookup(key) do
        {:ok, _} = hit ->
          hit

        :miss ->
          try do
            GenServer.call(
              __MODULE__,
              {:fetch, backend, base_url, model, key},
              @timeout_ms + 1_000
            )
          catch
            :exit, _ -> :error
          end
      end
    else
      _ -> :error
    end
  end

  @impl GenServer
  def init(_) do
    ensure_table()
    {:ok, %{}}
  end

  # Blocking HTTP is intentional: this call happens at most once per
  # (backend, base_url, model) tuple across the process lifetime — subsequent
  # calls hit the ETS cache directly and never reach the GenServer. Serialising
  # through the GenServer also prevents duplicate HTTP requests when two callers
  # race on the same key. The 3 s HTTP timeout is well within the 4 s
  # GenServer call timeout set by the caller.
  @impl GenServer
  def handle_call({:fetch, backend, base_url, model, key}, _from, state) do
    case ets_lookup(key) do
      {:ok, _} = hit ->
        {:reply, hit, state}

      :miss ->
        result =
          case do_fetch(backend, base_url, model) do
            {:ok, ctx} ->
              :ets.insert(@table, {key, ctx})
              {:ok, ctx}

            :error ->
              :error
          end

        {:reply, result, state}
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end
  end

  defp ets_lookup(key) do
    try do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> :miss
      end
    rescue
      ArgumentError -> :miss
    end
  end

  defp do_fetch(:ollama, base_url, model), do: fetch_ollama(base_url, model)
  defp do_fetch(:llamacpp, base_url, _model), do: fetch_llamacpp(base_url)
  defp do_fetch(:exo, base_url, model), do: fetch_exo(base_url, model)

  # Ollama advertises three different "context lengths" and only the smallest
  # is real:
  #
  #   * `model_info["<arch>.context_length"]` — the GGUF architecture ceiling
  #     (qwen3.6-a3b reports 262144). NOT what the runner allocated.
  #   * `parameters`' `num_ctx` — what the Modelfile asks the runner for.
  #   * `/api/ps` `context_length` — what the loaded runner actually serves,
  #     which is where `OLLAMA_CONTEXT_LENGTH` shows up for models whose
  #     Modelfile sets no `num_ctx` (default 4096 against a 262144 ceiling).
  #
  # Taking the minimum of whichever are present keeps compaction honest.
  # Over-reporting is the dangerous direction: the loop then compacts past
  # the point where the server has already silently truncated the prompt.
  defp fetch_ollama(base_url, model) do
    root = strip_openai_suffix(base_url)

    case Req.post(root <> "/api/show",
           json: %{"model" => model},
           receive_timeout: @timeout_ms,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        [
          num_ctx_parameter(body),
          arch_context_length(body),
          loaded_context_length(root, model)
        ]
        |> Enum.filter(&(is_integer(&1) and &1 > 0))
        |> case do
          [] -> :error
          found -> {:ok, Enum.min(found)}
        end

      {:ok, %Req.Response{}} ->
        :error

      {:error, _} ->
        :error
    end
  end

  # `parameters` is Ollama's rendered Modelfile parameter block, one
  # `<key><whitespace><value>` pair per line.
  defp num_ctx_parameter(%{"parameters" => params}) when is_binary(params) do
    case Regex.run(~r/^\s*num_ctx\s+(\d+)\s*$/m, params, capture: :all_but_first) do
      [n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp num_ctx_parameter(_), do: nil

  defp loaded_context_length(root, model) do
    case Req.get(root <> "/api/ps", receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"models" => models}}} when is_list(models) ->
        Enum.find_value(models, fn entry ->
          if entry["model"] == model or entry["name"] == model do
            case entry["context_length"] do
              n when is_integer(n) and n > 0 -> n
              _ -> nil
            end
          end
        end)

      _ ->
        nil
    end
  end

  defp fetch_llamacpp(base_url) do
    url = strip_openai_suffix(base_url) <> "/props"

    case Req.get(url, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case body do
          %{"default_generation_settings" => %{"n_ctx" => n_ctx}}
          when is_integer(n_ctx) and n_ctx > 0 ->
            {:ok, n_ctx}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp arch_context_length(%{"model_info" => model_info}) when is_map(model_info) do
    Enum.find_value(model_info, fn {k, v} ->
      if String.ends_with?(k, ".context_length") and is_integer(v) and v > 0, do: v
    end)
  end

  defp arch_context_length(_), do: nil

  defp fetch_exo(base_url, model) do
    url = strip_openai_suffix(base_url) <> "/v1/models"

    case Req.get(url, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        extract_exo_context(body, model)

      _ ->
        :error
    end
  end

  # exo model cards carry `context_length`; 0 means unknown.
  defp extract_exo_context(%{"data" => cards}, model) when is_list(cards) do
    Enum.find_value(cards, :error, fn
      %{"id" => ^model, "context_length" => ctx} when is_integer(ctx) and ctx > 0 -> {:ok, ctx}
      _ -> nil
    end)
  end

  defp extract_exo_context(_, _), do: :error

  defp resolve_base_url(opts, backend) do
    default =
      case backend do
        :ollama -> configured_ollama_url()
        :llamacpp -> configured_llamacpp_url()
        :exo -> configured_exo_url()
      end

    strip_openai_suffix(Keyword.get(opts, :base_url, default))
  end

  defp configured_ollama_url do
    :ex_athena
    |> Application.get_env(:ollama, [])
    |> Keyword.get(:base_url, @ollama_default)
  end

  defp configured_llamacpp_url do
    :ex_athena
    |> Application.get_env(:llamacpp, [])
    |> Keyword.get(:base_url, @llamacpp_default)
  end

  defp configured_exo_url do
    :ex_athena
    |> Application.get_env(:exo, [])
    |> Keyword.get(:base_url, @exo_default)
  end

  defp strip_openai_suffix(url) when is_binary(url) do
    url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end

  defp strip_provider_prefix(model, nil), do: model

  defp strip_provider_prefix(model, tag) when is_binary(tag) do
    prefix = tag <> ":"

    if String.starts_with?(model, prefix),
      do: String.replace_prefix(model, prefix, ""),
      else: model
  end
end
