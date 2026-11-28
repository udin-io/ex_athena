defmodule ExAthena.Chat.Permission do
  @moduledoc """
  How much the chat may do without asking: the one setting a person picks
  (issue 322), in place of the four chat modes.

    * `:read_only` — "Read only (plan)". The run is pinned to the `:plan`
      phase, so nothing changes. When the model has a plan it calls
      `plan_mode` with `action: "exit"`, and the person approves it with
      edits asked or allowed, or tells it to keep planning.
    * `:ask` — "Ask before edits". Each edit and each command that can change
      something asks Allow or Deny first.
    * `:edit` — "Edit freely". Edits run; commands that can change something
      still ask.
    * `:trusted` — "Trusted". Everything runs.

  The front end supplies how to ask (`ask` below) and runs `run_opts/2`'s
  result. Reading and searching files, the to-do list, questions, `finish`,
  skills and helpers never ask. Below Trusted, every command asks (in Read
  only, only commands that pass the read-only test may run at all), a web
  fetch, a web search and a GitHub command ask, and the language server asks once per run, since it
  compiles the project. A helper is held to its parent's level: it inherits
  the parent's phase and this callback (`ExAthena.Tools.SpawnAgent`), and it
  cannot leave Read only on its own.

  The level lives in an `:atomics` cell for the whole run, helpers included,
  and is read at every tool call. A plan approved "edit freely" lets the run's
  later edits through without a restart, and a front end moves a running run
  to the level a person picks with `put/2` (issue 333), up or down.

  A run started Read only stays in the read-only phase until its plan is
  approved, whatever level is picked meanwhile; the approval sets the level.
  A run moved to Read only mid-run refuses what that phase refuses.
  """

  alias ExAthena.Permissions

  @levels [:read_only, :ask, :edit, :trusted]

  @labels %{
    read_only: "Read only (plan)",
    ask: "Ask before edits",
    edit: "Edit freely",
    trusted: "Trusted"
  }

  @never_ask ~w(todo_write ask_user finish skill read_summary read_worker_report)

  # A run moved to Read only mid-run keeps its phase, so its prompt never
  # gained the read-only note; the refusal carries it instead.
  @now_read_only "The person made this chat read only. Change nothing: look around with " <>
                   "the read-only tools, then call plan_mode with action \"exit\" and your " <>
                   "plan in `plan`, one step per line. The person approves it before anything changes."

  @helper_read_only "The person made this chat read only. Change nothing; put what you " <>
                      "would do in your report to the chat that sent you."

  @approve_ask "Yes, and ask before each edit"
  @approve_edit "Yes, and edit freely"
  @keep_planning "No, keep planning"

  @type level :: :read_only | :ask | :edit | :trusted

  @typedoc "Puts a question to the person and returns the answer text."
  @type ask ::
          (question :: String.t(), options :: [String.t()], :plan_approval | :approval ->
             String.t() | :gone)

  @doc "The four levels, in the order a picker shows them."
  @spec levels() :: [level()]
  def levels, do: @levels

  @doc "The words a person reads for `level`."
  @spec label(level()) :: String.t()
  def label(level), do: Map.fetch!(@labels, level)

  @doc "The default level: Ask before edits."
  @spec default() :: level()
  def default, do: :ask

  @doc """
  The level a stored or typed value names, or `default/0`.

  Takes the atom or its string (`"read_only"`, `"ask"`, `"edit"`,
  `"trusted"`) and never creates an atom.

      iex> ExAthena.Chat.Permission.parse("edit")
      :edit
      iex> ExAthena.Chat.Permission.parse("orchestrate")
      :ask
  """
  @spec parse(term()) :: level()
  def parse(level) when level in @levels, do: level

  def parse(text) when is_binary(text),
    do: Enum.find(@levels, default(), &(Atom.to_string(&1) == text))

  def parse(_), do: default()

  @doc """
  The run options for `level`: the `:phase`, and a `:can_use_tool` that asks
  through `ask`.

  `ask` gets the question, its options and its kind (`:plan_approval` or
  `:approval`), and returns the answer, or `:gone` when nobody is there to
  answer; a gone answer denies. A front end moves its picker only on a
  `:plan_approval` answer, never on a question the model wrote. The returned
  `:level_ref` holds the run's level: a plan approval moves it, and so does
  `put/2`.

  Trusted runs in the `:default` phase so that every call still reaches the
  level, which lets a lowered level take effect at once. It carries
  `permission_mode: :bypass_permissions` for providers that run their own
  tools and never ask (`ExAthena.Providers.ClaudeCode`).
  """
  @spec run_opts(level(), ask()) :: keyword()
  def run_opts(level, ask) when level in @levels and is_function(ask, 3) do
    # Slot 1: the level. Slot 2: 1 once the person allowed the language
    # server for this run.
    ref = :atomics.new(2, [])
    put(ref, level)

    [
      phase: phase(level),
      can_use_tool: fn name, args, ctx -> decide(ref, name, args, ctx, ask) end,
      level_ref: ref
    ]
    |> put_bypass(level)
  end

  defp put_bypass(opts, :trusted), do: Keyword.put(opts, :permission_mode, :bypass_permissions)
  defp put_bypass(opts, _level), do: opts

  @doc """
  The level a plan approval's answer moves the chat to, or nil when the answer
  is not an approval. A front end uses it to move its picker.

      iex> ExAthena.Chat.Permission.level_after_approval("Yes, and edit freely")
      :edit
      iex> ExAthena.Chat.Permission.level_after_approval("No, keep planning")
      nil
  """
  @spec level_after_approval(term()) :: level() | nil
  def level_after_approval(@approve_ask), do: :ask
  def level_after_approval(@approve_edit), do: :edit
  def level_after_approval(_), do: nil

  @doc "The level a run's `:level_ref` holds now."
  @spec current(:atomics.atomics_ref()) :: level()
  def current(ref), do: Enum.at(@levels, :atomics.get(ref, 1))

  @doc """
  Moves a run to `level`: its next tool call, and its helpers' next calls,
  follow it.
  """
  @spec put(:atomics.atomics_ref(), level()) :: :ok
  def put(ref, level) when level in @levels,
    do: :atomics.put(ref, 1, Enum.find_index(@levels, &(&1 == level)))

  defp phase(:read_only), do: :plan
  defp phase(_), do: :default

  defp decide(ref, "plan_mode", %{"action" => "exit"} = args, ctx, ask) do
    if helper?(ctx) do
      # A helper's plan is not the chat's. Its approval would look like the
      # chat's own and move the level for the whole run.
      {:deny,
       "A helper cannot leave read only. Put the plan in your report to the chat that sent you."}
    else
      approve_plan(ref, args, ask)
    end
  end

  defp decide(ref, name, args, ctx, ask) do
    level = current(ref)

    cond do
      level == :trusted -> :allow
      level == :read_only and refused_read_only?(name, args, ctx) -> read_only_refusal(ctx)
      quiet?(name, args, level) -> :allow
      level == :edit and name in ~w(write edit apply_patch) -> :allow
      true -> ask_once(ref, name, args, ctx, ask)
    end
  end

  defp helper?(%{assigns: assigns}) when is_map(assigns),
    do: Map.get(assigns, :agent_depth, 0) > 0

  defp helper?(_ctx), do: false

  # A helper holds no plan_mode, and its plan is not the chat's.
  defp read_only_refusal(ctx) do
    if helper?(ctx),
      do: {:deny, @helper_read_only},
      else: {:deny, @now_read_only}
  end

  # A run moved to Read only mid-run keeps the phase it started in, so the
  # level refuses what the read-only phase would. In that phase the phase
  # itself already refused it.
  defp refused_read_only?(_name, _args, %{phase: :plan}), do: false

  # An agent definition can name its own provider, and the Claude Code CLI
  # never asks: it would take the phase this run started in, not Read only.
  # A plain helper runs in-process and reads this level.
  defp refused_read_only?("spawn_agent", %{"agent" => agent}, _ctx)
       when is_binary(agent) and agent != "",
       do: true

  defp refused_read_only?("bash", args, _ctx),
    do: ExAthena.Tools.Bash.read_only_violation(args) != nil

  defp refused_read_only?(name, _args, _ctx),
    do: name not in @never_ask and name not in Permissions.readonly_tools()

  defp approve_plan(ref, args, ask) do
    plan = args |> Map.get("plan", "") |> to_string() |> String.trim()

    question =
      if plan == "",
        do: "The chat wants to start making changes. Go ahead?",
        else: "The chat's plan:\n\n" <> plan <> "\n\nGo ahead?"

    case ask.(question, [@approve_ask, @approve_edit, @keep_planning], :plan_approval) do
      @approve_ask ->
        put(ref, :ask)
        :allow

      @approve_edit ->
        put(ref, :edit)
        :allow

      @keep_planning ->
        {:deny, "The person wants you to keep planning. Change nothing yet."}

      :gone ->
        {:deny, "Nobody is there to approve the plan. Change nothing."}

      other ->
        {:deny, "The person wants you to keep planning, and said: " <> to_string(other)}
    end
  end

  # What never asks. A command asks at every level below Trusted, Read only
  # included: the read-only test (`ExAthena.Tools.Bash.read_only_command?/1`)
  # reads a command's words, and a shell builds words it cannot see (four
  # review rounds each found another way past it). In Read only the phase
  # still refuses outright any command that fails the test.
  # Fetching from the web and calling GitHub ask too, since a request can
  # carry data out. The
  # language server compiles the project, so it asks once per run.
  @ask_always ~w(bash web_fetch web_search gh lsp)

  defp quiet?(name, _args, _level) do
    name not in @ask_always and
      (name in @never_ask or name in Permissions.readonly_tools())
  end

  defp ask_once(ref, name, args, ctx, ask) do
    if name == "lsp" and :atomics.get(ref, 2) == 1,
      do: :allow,
      else: ask(ref, name, args, ctx, ask)
  end

  defp ask(ref, name, args, ctx, ask) do
    case ask.(describe(name, args), ["Allow", "Deny"], :approval) do
      "Allow" ->
        allowed(ref, name, args, ctx)

      :gone ->
        {:deny, "Nobody is there to approve this. Do not try it again."}

      _ ->
        {:deny, "The person did not allow this. Do not try it again; ask or move on."}
    end
  end

  # The level can move while the question is on screen: an Allow given after
  # the person picked Read only does not let a change through.
  defp allowed(ref, name, args, ctx) do
    if current(ref) == :read_only and refused_read_only?(name, args, ctx) do
      read_only_refusal(ctx)
    else
      if name == "lsp", do: :atomics.put(ref, 2, 1)
      :allow
    end
  end

  defp describe("bash", %{"command" => cmd}), do: "Run this command?\n\n" <> to_string(cmd)

  defp describe(name, %{"path" => path}) when name in ~w(write edit),
    do: "Change #{path}?"

  defp describe("apply_patch", _args), do: "Apply a patch to your files?"

  defp describe("web_fetch", %{"url" => url}), do: "Fetch this page?\n\n" <> to_string(url)

  defp describe("web_search", %{"query" => q}),
    do: "Search the web for this?\n\n" <> to_string(q)

  defp describe("gh", %{"command" => cmd}),
    do: "Run this GitHub command?\n\ngh " <> to_string(cmd)

  defp describe("lsp", _args),
    do: "Start the language server? It compiles the project, which runs its code."

  defp describe(name, _args), do: "Let the chat use #{name}?"
end
