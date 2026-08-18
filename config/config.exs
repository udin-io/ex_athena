import Config

if config_env() == :test do
  config :ex_athena, enable_mcp: false
end

# The :claude_code provider drives the locally-installed, logged-in `claude` CLI
# (subscription/OAuth — no API key). Use the existing system binary instead of
# the SDK's default `:bundled` mode, which re-installs its own pinned CLI version
# on every session start whenever the local CLI version differs.
config :claude_code, cli_path: :global

# Web search backend for the `web_search` tool. Default is DuckDuckGo (no API
# key — parses the HTML SERP, best-effort/rate-limited). Swap the backend (and
# supply api_key/endpoint) via env in config/runtime.exs. config/test.exs
# overrides the adapter with a Mox mock.
config :ex_athena, :search,
  adapter: ExAthena.Search.Http,
  backend: :duckduckgo

# Max agent nesting depth (0 = orchestrator, 1 = its workers, 2+ = nested).
# Agents may delegate sub-agents up to this depth; the ceiling prevents an
# unbounded worker tree from wedging the single GPU slot. Override per-run via
# spawn_agent_opts / assigns[:max_agent_depth].
config :ex_athena, max_agent_depth: 5

# Tunable rails. Every key below defaults to the value the rail was first
# tuned to, so leaving this commented out changes nothing. Raise or lower
# them when running a model with a different context, planning style, or
# delegation latency. See `ExAthena.Tuning`.
#
# config :ex_athena, :orchestrate,
#   max_planning_turns: 8,             # planning turns before forcing execution
#   max_turns_without_spawn: 2,        # spawn-less turns before the runtime delegates for you
#   research_planning_threshold: 4,    # planning turns before nudging toward research
#   research_escalation_threshold: 6,  # planning turns before the runtime spawns research itself
#   max_dictated_briefs: 2,            # briefs containing dictated code before warning
#   max_same_objective: 3,             # repeats of one objective before it is called out
#   audit_request_chars: 1_500         # request text quoted into the audit prompt
#
# config :ex_athena, :agents,
#   max_iterations: 50,                # floor on a worker's iteration budget
#   result_chars: 64_000,              # cap on the report a worker returns to its parent
#   dictated_code_lines: 8,            # fenced lines before a brief counts as dictated code
#   prompt_chars: 160,                 # brief shown in the agent overview panel
#   transcript_max_entries: 30,        # transcript rows kept per agent
#   transcript_entry_chars: 400,       # cap per non-text transcript row
#   transcript_text_chars: 4_000,      # cap per text transcript row
#   conclusions_cap: 50                # conclusions retained per agent
#
# config :ex_athena, :web,
#   max_retained_events: 2_000         # events a run replays to a reattaching browser
#
# config :ex_athena, :bash,
#   max_output_chars: 16_000           # command output cap (head 75% / tail 25%)

import_config "#{config_env()}.exs"

# To use a local llama.cpp server instead:
#
#   mix athena.chat --provider llamacpp
#
# or set it as the default:
#
#   config :ex_athena, default_provider: :llamacpp
