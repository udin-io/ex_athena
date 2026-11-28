defmodule ExAthena.Chat.Session do
  @moduledoc """
  In-memory state for one interactive `mix athena.chat` session.

  Plain struct + transformation functions — deliberately not a GenServer.
  The REPL is single-process and synchronous; each turn produces a new
  `%Session{}` from the previous one.
  """

  alias ExAthena.Chats
  alias ExAthena.Messages
  alias ExAthena.Messages.{Message, ToolResult}
  alias ExAthena.Result

  @saved_fields [:cwd, :provider, :model, :permission]
  @title_chars 60

  @default_model "llama3.1"

  defstruct provider: :ollama,
            model: @default_model,
            permission: :ask,
            tools: :all,
            messages: [],
            iteration: 0,
            usage: %{input_tokens: 0, output_tokens: 0},
            cost_usd: 0.0,
            cwd: nil,
            provider_session_id: nil,
            chat_id: nil,
            saved: nil,
            version: nil,
            saved_sig: nil

  @type t :: %__MODULE__{
          provider: atom(),
          model: String.t(),
          permission: ExAthena.Chat.Permission.level(),
          tools: :all | [module()],
          messages: [Message.t()],
          iteration: non_neg_integer(),
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
          cost_usd: float(),
          cwd: String.t() | nil,
          provider_session_id: String.t() | nil,
          chat_id: Chats.id(),
          saved: map() | nil,
          version: non_neg_integer() | nil,
          saved_sig: integer() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    provider =
      Keyword.get(opts, :provider) ||
        Application.get_env(:ex_athena, :default_provider, :ollama)

    provider_config = Application.get_env(:ex_athena, provider, [])
    configured_model = Keyword.get(provider_config, :model, @default_model)

    %__MODULE__{
      provider: provider,
      model: Keyword.get(opts, :model, configured_model),
      permission: ExAthena.Chat.Permission.parse(Keyword.get(opts, :permission, :ask)),
      tools: Keyword.get(opts, :tools, :all),
      cwd: Keyword.get(opts, :cwd),
      chat_id: Chats.new_id()
    }
  end

  @doc """
  Save the chat to its record (`ExAthena.Chats`): the first save starts the
  record, titled by the first message; each later one adds the new messages
  and any changed folder, provider, model or permission. A chat with no
  messages yet is not saved.

  The write is conditional on the record not having moved since this session
  read or wrote it. When another front end added a turn or rewound the chat
  meanwhile, nothing is written over that: this session's history is saved
  as a new chat forked from it, and `{:moved, session}` returns the session
  on that new chat.
  """
  @spec save(t()) :: {:ok, t()} | {:moved, t()} | {:error, term()}
  def save(%__MODULE__{messages: []} = session), do: {:ok, session}

  def save(%__MODULE__{} = session) do
    fields = saved_fields(session)

    # Nothing new since the last save: write nothing, so quitting an idle
    # window never turns another window's newer turn into a stale copy.
    same_messages? =
      session.version != nil and session.saved_sig == :erlang.phash2(session.messages)

    cond do
      same_messages? and session.saved == fields ->
        {:ok, session}

      # Only a setting changed: record it, and never fork over a chat that
      # another window went on with.
      same_messages? ->
        with :ok <- write_header(session, fields), do: {:ok, %{session | saved: fields}}

      true ->
        write(session, fields)
    end
  end

  defp write(session, fields) do
    case Chats.sync(session.chat_id, session.messages, [return: :version] ++ expect_opts(session)) do
      {:ok, version} ->
        with :ok <- write_header(session, fields),
             do:
               {:ok,
                %{
                  session
                  | saved: fields,
                    version: version,
                    saved_sig: :erlang.phash2(session.messages)
                }}

      {:error, :not_found} ->
        with :ok <- write_header(%{session | saved: nil}, fields),
             {:ok, version} <- Chats.sync(session.chat_id, session.messages, return: :version) do
          {:ok,
           %{
             session
             | saved: fields,
               version: version,
               saved_sig: :erlang.phash2(session.messages)
           }}
        end

      {:error, :moved} ->
        save_as_fork(session, fields)

      err ->
        err
    end
  end

  defp expect_opts(%{version: nil}), do: []
  defp expect_opts(%{version: v}), do: [expect: v]

  @doc """
  Before a turn: when another window went on with this chat since this
  session read it, this session's copy goes on as a new chat forked from it
  (`{:moved, session}`), so the turn's file edits are recorded under the chat
  they belong to.
  """
  @spec fork_if_moved(t()) :: {:ok, t()} | {:moved, t()} | {:error, term()}
  def fork_if_moved(%__MODULE__{version: nil} = session), do: {:ok, session}

  def fork_if_moved(%__MODULE__{} = session) do
    case Chats.version(session.chat_id) do
      {:ok, v} when v != session.version -> save_as_fork(session, saved_fields(session))
      _ -> {:ok, session}
    end
  end

  defp save_as_fork(session, fields) do
    attrs =
      Map.merge(fields, %{
        title: title(session.messages),
        forked_from: %{chat: session.chat_id, step: nil}
      })

    with {:ok, %{id: id}} <- Chats.create(attrs),
         {:ok, version} <- Chats.sync(id, session.messages, return: :version) do
      {:moved,
       %{
         session
         | chat_id: id,
           saved: fields,
           version: version,
           saved_sig: :erlang.phash2(session.messages)
       }}
    end
  end

  defp write_header(%{saved: nil} = session, fields) do
    case Chats.create(Map.merge(fields, %{id: session.chat_id, title: title(session.messages)})) do
      {:ok, _} -> :ok
      {:error, :exists} -> Chats.update(session.chat_id, fields)
      err -> err
    end
  end

  defp write_header(%{saved: saved} = session, fields) do
    Chats.update(session.chat_id, Map.reject(fields, fn {k, v} -> Map.get(saved, k) == v end))
  end

  defp saved_fields(session) do
    session
    |> Map.take(@saved_fields)
    |> Map.put(:cwd, session.cwd || File.cwd!())
  end

  defp title(messages) do
    Enum.find_value(messages, "New chat", fn
      %Message{role: :user, content: text} when is_binary(text) ->
        text |> String.split("\n", trim: true) |> List.first("") |> String.slice(0, @title_chars)

      _ ->
        nil
    end)
  end

  @doc """
  Open a saved chat as a session. `opts` given here (`:model`, `:provider`,
  `:permission`, `:cwd`, `:tools`) win over the saved values.
  """
  @spec open(Chats.id(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(chat_id, opts \\ []) do
    with {:ok, chat} <- Chats.load(chat_id) do
      session = %__MODULE__{
        provider: Keyword.get(opts, :provider, provider_atom(chat[:provider])),
        model: Keyword.get(opts, :model, chat[:model] || @default_model),
        permission:
          ExAthena.Chat.Permission.parse(
            Keyword.get(opts, :permission, chat[:permission] || :ask)
          ),
        tools: Keyword.get(opts, :tools, :all),
        cwd: Keyword.get(opts, :cwd, chat[:cwd]),
        messages: chat.messages,
        chat_id: chat.id
      }

      {:ok,
       %{
         session
         | saved: Map.take(chat, @saved_fields),
           version: chat.version,
           saved_sig: :erlang.phash2(chat.messages)
       }}
    end
  end

  # The web UI may save a provider name this program has no atom for.
  defp provider_atom(p) when is_atom(p) and not is_nil(p), do: p

  defp provider_atom(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> :ollama
  end

  defp provider_atom(_), do: :ollama

  @doc "The id of the newest saved chat of folder `cwd`, or nil."
  @spec latest(String.t()) :: Chats.id() | nil
  def latest(cwd) when is_binary(cwd) do
    case Chats.list(cwd: cwd) do
      [%{id: id} | _] -> id
      [] -> nil
    end
  end

  @spec set_cwd(t(), String.t() | nil) :: t()
  def set_cwd(%__MODULE__{} = session, cwd) when is_binary(cwd) or is_nil(cwd) do
    %{session | cwd: cwd}
  end

  @spec append_user(t(), String.t()) :: t()
  def append_user(%__MODULE__{messages: msgs} = session, text) when is_binary(text) do
    %{session | messages: msgs ++ [Messages.user(text)]}
  end

  @spec clear_messages(t()) :: t()
  def clear_messages(%__MODULE__{} = session) do
    %{
      session
      | messages: [],
        iteration: 0,
        usage: %{input_tokens: 0, output_tokens: 0},
        cost_usd: 0.0,
        provider_session_id: nil,
        chat_id: Chats.new_id(),
        saved: nil,
        version: nil
    }
  end

  @spec set_model(t(), String.t()) :: t()
  def set_model(%__MODULE__{} = session, model) when is_binary(model) do
    %{session | model: model}
  end

  @doc "Set how much the chat may do without asking (`ExAthena.Chat.Permission`)."
  @spec set_permission(t(), ExAthena.Chat.Permission.level()) :: t()
  def set_permission(%__MODULE__{} = session, level) do
    %{session | permission: ExAthena.Chat.Permission.parse(level)}
  end

  @spec set_provider(t(), atom()) :: t()
  def set_provider(%__MODULE__{} = session, provider) when is_atom(provider) do
    # The resume session id belongs to the previous provider's server-side
    # conversation — it has no meaning for the new one.
    %{session | provider: provider, provider_session_id: nil}
  end

  @doc """
  Extract every `ToolResult` from the session's message history, ordered
  most-recent first.

  Used by `/expand` in the REPL so the user can reference recent tool
  outputs by position (`/expand 1` for the latest, `/expand 2` for the
  one before, etc.).
  """
  @spec tool_results(t()) :: [ToolResult.t()]
  def tool_results(%__MODULE__{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(&(&1.tool_results || []))
    |> Enum.reverse()
  end

  @spec apply_result(t(), Result.t()) :: t()
  def apply_result(%__MODULE__{} = session, %Result{} = result) do
    new_messages =
      case result.messages do
        [] -> session.messages
        msgs when is_list(msgs) -> msgs
      end

    delta_usage = result.usage || %{}

    merged_usage = %{
      input_tokens: session.usage.input_tokens + Map.get(delta_usage, :input_tokens, 0),
      output_tokens: session.usage.output_tokens + Map.get(delta_usage, :output_tokens, 0)
    }

    %{
      session
      | messages: new_messages,
        usage: merged_usage,
        cost_usd: session.cost_usd + (result.cost_usd || 0.0),
        iteration: result.iterations || session.iteration,
        # Keep the latest provider session id for `resume:`; a result without
        # one (stateless provider, error run) must not wipe resume state.
        provider_session_id: result.session_id || session.provider_session_id
    }
  end
end
