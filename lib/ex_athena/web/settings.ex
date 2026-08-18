defmodule ExAthena.Web.Settings do
  @moduledoc """
  User-editable tuning settings, backed by the web UI's gear modal.

  `ExAthena.Tuning` made the rails configurable; they still lived in
  `config.exs`, so changing one meant editing source and restarting. This
  module puts the same keys behind a form: values are validated, written to
  `~/.ex_athena/web/settings.json`, and applied to the application
  environment immediately — the next run picks them up without a restart.
  `load/0` re-applies them at boot.

  The schema below is the single source of truth. It drives the modal's
  rendering, the validation, and the set of keys allowed to reach the
  application environment — a form posts whatever the page contained, and app
  env is global process state, so an unknown key is dropped rather than
  written.

  Defaults here intentionally repeat the module attributes they mirror. That
  duplication is deliberate: the attribute is the behavioural default used
  when nothing is configured at all (including for hosts that never open the
  web UI), and this is the value the form shows. A test asserts the schema
  covers every field so the two cannot silently diverge in *coverage*; a
  mismatch in *value* only changes what the form pre-fills.
  """

  require Logger

  @default_path Path.expand("~/.ex_athena/web/settings.json")

  @schema [
    %{
      ns: :orchestrate,
      title: "Orchestration",
      blurb: "When the orchestrator stops planning and starts delegating.",
      fields: [
        %{
          key: :max_planning_turns,
          label: "Max planning turns",
          default: 8,
          type: :integer,
          min: 1,
          help: "Planning turns before execution is forced."
        },
        %{
          key: :max_turns_without_spawn,
          label: "Turns before auto-delegate",
          default: 2,
          type: :integer,
          min: 0,
          help: "Spawn-less turns with pending todos before the runtime delegates for you."
        },
        %{
          key: :research_planning_threshold,
          label: "Research nudge after",
          default: 4,
          type: :integer,
          min: 1,
          help: "Planning turns before the orchestrator is nudged toward research."
        },
        %{
          key: :research_escalation_threshold,
          label: "Research escalation after",
          default: 6,
          type: :integer,
          min: 1,
          help: "Planning turns before the runtime spawns a research worker itself."
        },
        %{
          key: :max_dictated_briefs,
          label: "Dictated briefs before warning",
          default: 2,
          type: :integer,
          min: 1,
          help: "Briefs containing dictated code before the orchestrator is told to stop."
        },
        %{
          key: :max_same_objective,
          label: "Repeats of one objective",
          default: 3,
          type: :integer,
          min: 1,
          help: "Times the same objective may be delegated before it is called out."
        },
        %{
          key: :audit_request_chars,
          label: "Audit request chars",
          default: 1_500,
          type: :integer,
          min: 100,
          help: "How much of the original request is quoted into the audit prompt."
        }
      ]
    },
    %{
      ns: :agents,
      title: "Workers",
      blurb: "Per-worker budgets and the record kept of each one.",
      fields: [
        %{
          key: :max_iterations,
          label: "Min iteration budget",
          default: 50,
          type: :integer,
          min: 1,
          help: "Floor on a worker's iteration budget."
        },
        %{
          key: :result_chars,
          label: "Report cap (chars)",
          default: 64_000,
          type: :integer,
          min: 1_000,
          help:
            "Cap on the report a worker returns to its parent. Was 8k; clipped 15% of reports."
        },
        %{
          key: :dictated_code_lines,
          label: "Dictated-code threshold (lines)",
          default: 8,
          type: :integer,
          min: 1,
          help: "Fenced lines in a brief before it counts as dictating code."
        },
        %{
          key: :prompt_chars,
          label: "Brief shown in overview (chars)",
          default: 160,
          type: :integer,
          min: 40,
          help: "How much of a worker's brief the agent panel shows. Real briefs median ~1,000."
        },
        %{
          key: :transcript_max_entries,
          label: "Transcript rows kept",
          default: 30,
          type: :integer,
          min: 1,
          help: "Rows retained per agent transcript."
        },
        %{
          key: :transcript_entry_chars,
          label: "Transcript row cap (chars)",
          default: 400,
          type: :integer,
          min: 50,
          help: "Cap per non-text transcript row."
        },
        %{
          key: :transcript_text_chars,
          label: "Transcript text cap (chars)",
          default: 4_000,
          type: :integer,
          min: 100,
          help: "Cap per text transcript row."
        },
        %{
          key: :conclusions_cap,
          label: "Conclusions kept",
          default: 50,
          type: :integer,
          min: 1,
          help: "Conclusions retained per agent."
        }
      ]
    },
    %{
      ns: :model,
      title: "Model",
      blurb: "Sent with every request. Support varies by model and provider.",
      fields: [
        %{
          key: :reasoning_effort,
          label: "Reasoning effort",
          default: :default,
          type: :select,
          options: [:default, :none, :minimal, :low, :medium, :high, :xhigh],
          help:
            "Forwarded as `reasoning_effort`. `default` sends nothing; `none` disables thinking. " <>
              "Verified on Ollama 0.32 with qwen3.8 — `none` returns no reasoning at all."
        }
      ]
    },
    %{
      ns: :web,
      title: "Run record",
      blurb: "What a run keeps so a reloaded browser can rebuild it.",
      fields: [
        %{
          key: :max_retained_events,
          label: "Events retained per run",
          default: 2_000,
          type: :integer,
          min: 100,
          help: "Events replayed to a browser that reattaches mid-run."
        }
      ]
    },
    %{
      ns: :bash,
      title: "Shell",
      blurb: nil,
      fields: [
        %{
          key: :max_output_chars,
          label: "Command output cap (chars)",
          default: 16_000,
          type: :integer,
          min: 1_000,
          help: "Head keeps 75%, tail 25%. An uncapped `find .` once cost 204k input tokens."
        }
      ]
    }
  ]

  @doc "Field groups, in display order."
  @spec schema() :: [map()]
  def schema, do: @schema

  @doc "Every namespace the schema writes to."
  @spec namespaces() :: [atom()]
  def namespaces, do: Enum.map(@schema, & &1.ns)

  @doc """
  Current effective value for each field, keyed `{namespace, key}`.

  Reads through `ExAthena.Tuning`, so a value set in `config.exs` shows in the
  form even though it was never saved here.
  """
  @spec values() :: %{{atom(), atom()} => term()}
  def values do
    for group <- @schema, field <- group.fields, into: %{} do
      {{group.ns, field.key}, ExAthena.Tuning.get(group.ns, field.key, field.default)}
    end
  end

  @doc "Whether `{ns, key}` currently differs from its built-in default."
  @spec overridden?({atom(), atom()}) :: boolean()
  def overridden?({ns, key} = id) do
    case field(ns, key) do
      nil -> false
      f -> Map.get(values(), id) != f.default
    end
  end

  @doc """
  Validate `params` (a flat `"namespace.key" => string` map from the form),
  apply what is valid, and persist.

  Returns `{:ok, applied}` or `{:error, errors}` keyed by `{ns, key}`. Valid
  fields are applied even when a sibling fails — a typo in one box should not
  discard the other edits the user just made.
  """
  @spec save(map()) :: {:ok, map()} | {:error, map()}
  def save(params) when is_map(params) do
    {applied, errors} =
      Enum.reduce(params, {%{}, %{}}, fn {raw_key, raw_value}, {ok, bad} ->
        case parse(raw_key, raw_value) do
          {:ok, id, value} -> {Map.put(ok, id, value), bad}
          {:error, id, message} -> {ok, Map.put(bad, id, message)}
          :ignore -> {ok, bad}
        end
      end)

    apply_values(applied)
    persist()

    if errors == %{}, do: {:ok, applied}, else: {:error, errors}
  end

  @doc "Apply the persisted settings file to the application environment."
  @spec load() :: :ok
  def load do
    case read_file() do
      {:ok, stored} ->
        stored
        |> Enum.flat_map(fn {ns_str, keys} ->
          Enum.flat_map(keys, fn {key_str, value} ->
            case field_by_strings(ns_str, key_str) do
              nil -> []
              {ns, f} -> [{{ns, f.key}, coerce_stored(f, value)}]
            end
          end)
        end)
        |> Map.new()
        |> apply_values()

      :error ->
        :ok
    end

    :ok
  end

  @doc "Drop every saved override and return all fields to their defaults."
  @spec reset() :: :ok
  def reset do
    for ns <- namespaces(), do: Application.delete_env(:ex_athena, ns)
    File.rm(path())
    :ok
  end

  @doc """
  Provider options implied by the current settings, ready to merge into a
  run's opts.

  `reasoning_effort: :default` means "send nothing" — the model's own default
  is not the same as any named level, and forwarding a level the provider
  ignores is not free (Ollama's OpenAI endpoint accepts the key and changes
  behaviour; other backends may reject an unknown one).
  """
  @spec provider_opts() :: keyword()
  def provider_opts do
    case ExAthena.Tuning.get(:model, :reasoning_effort, :default) do
      :default -> []
      effort when is_atom(effort) -> [reasoning_effort: effort]
      _ -> []
    end
  end

  @doc "Where settings are stored. Override with `config :ex_athena, :settings_path`."
  @spec path() :: String.t()
  def path, do: Application.get_env(:ex_athena, :settings_path, @default_path)

  # ── Internal ──────────────────────────────────────────────────────

  defp parse(raw_key, raw_value) do
    with [ns_str, key_str] <- String.split(to_string(raw_key), ".", parts: 2),
         {ns, f} when not is_nil(f) <- field_by_strings(ns_str, key_str) || {nil, nil} do
      validate(ns, f, raw_value)
    else
      _ -> :ignore
    end
  end

  defp validate(ns, %{type: :integer} = f, raw) do
    case Integer.parse(String.trim(to_string(raw))) do
      {n, ""} when n >= 0 ->
        min = Map.get(f, :min, 0)

        if n >= min,
          do: {:ok, {ns, f.key}, n},
          else: {:error, {ns, f.key}, "must be at least #{min}"}

      _ ->
        {:error, {ns, f.key}, "must be a whole number"}
    end
  end

  defp validate(ns, %{type: :select, options: options} = f, raw) do
    value = raw |> to_string() |> String.trim()
    allowed = Enum.map(options, &to_string/1)

    if value in allowed do
      {:ok, {ns, f.key}, String.to_existing_atom(value)}
    else
      {:error, {ns, f.key}, "must be one of: #{Enum.join(allowed, ", ")}"}
    end
  end

  defp apply_values(values) when map_size(values) == 0, do: :ok

  defp apply_values(values) do
    values
    |> Enum.group_by(fn {{ns, _}, _} -> ns end, fn {{_, key}, value} -> {key, value} end)
    |> Enum.each(fn {ns, pairs} ->
      current = Application.get_env(:ex_athena, ns, [])
      current = if Keyword.keyword?(current), do: current, else: []
      Application.put_env(:ex_athena, ns, Keyword.merge(current, pairs))
    end)
  end

  # Persist the CURRENT effective state rather than just this submission, so a
  # partially-failed save still writes a complete, reloadable file.
  defp persist do
    payload =
      for group <- @schema, field <- group.fields, reduce: %{} do
        acc ->
          value = ExAthena.Tuning.get(group.ns, field.key, field.default)

          if value == field.default do
            acc
          else
            ns = to_string(group.ns)
            keys = Map.get(acc, ns, %{})
            Map.put(acc, ns, Map.put(keys, to_string(field.key), serialize(value)))
          end
      end

    file = path()
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Jason.encode!(payload))
    :ok
  rescue
    e ->
      Logger.warning("could not persist settings: #{Exception.message(e)}")
      :ok
  end

  defp serialize(v) when is_atom(v), do: to_string(v)
  defp serialize(v), do: v

  defp coerce_stored(%{type: :select}, v) when is_binary(v), do: String.to_existing_atom(v)
  defp coerce_stored(_f, v), do: v

  defp read_file do
    with {:ok, body} <- File.read(path()),
         {:ok, data} when is_map(data) <- Jason.decode(body) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  defp field(ns, key) do
    Enum.find_value(@schema, fn
      %{ns: ^ns, fields: fields} -> Enum.find(fields, &(&1.key == key))
      _ -> nil
    end)
  end

  # String lookup never calls String.to_atom/1 — a form (or a hand-edited
  # settings file) is external input, and app env keys are atoms.
  defp field_by_strings(ns_str, key_str) do
    Enum.find_value(@schema, fn group ->
      if to_string(group.ns) == ns_str do
        case Enum.find(group.fields, &(to_string(&1.key) == key_str)) do
          nil -> nil
          f -> {group.ns, f}
        end
      end
    end)
  end
end
