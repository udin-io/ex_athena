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

import_config "#{config_env()}.exs"

# config :ex_athena, :openai_compatible,
#   base_url: "https://api.openai.com/v1",
#   model: "gpt-4o-mini"

config :ex_athena, :llamacpp, base_url: "http://192.168.0.238:8181", model: "qwen36-35b"

config :ex_athena, :openai_compatible,
  base_url: "http://192.168.0.238:8181/v1",
  model: "qwen36-35b",
  api_key: System.get_env("OPENAI_API_KEY")

config :ex_athena, default_provider: :ollama

config :ex_athena, :ollama, base_url: "http://192.168.0.238:11434", model: "qwen3.6:35b-a3b-128k"
# To use a local llama.cpp server instead:,
#
#   mix athena.chat --provider llamacpp
#
# or set it as the default:
#
config :ex_athena, default_provider: :llamacpp
