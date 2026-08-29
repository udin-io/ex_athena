import Config

# Disable LSP supervisor during tests so individual test cases can start
# their own isolated supervision trees via start_supervised!/1.
config :ex_athena, enable_lsp: false

# Disable sweepers that are not needed during tests.
config :ex_athena, enable_worktree_sweeper: false
config :ex_athena, enable_checkpoint_sweeper: false

# Disable ProviderRegistry at the application level so each test can start
# its own isolated instance via start_supervised!/1.
config :ex_athena, enable_provider_registry: false

# Disable implicit LSP diagnostics hook globally in tests so existing tests
# are not affected. Individual ImplicitDiagnostics tests opt back in.
config :ex_athena, lsp_implicit_diagnostics_enabled: false

# Disable request queue supervisor; individual tests opt in via start_supervised!.
config :ex_athena, :request_queue, enabled: false

# Route web_search through the Mox mock (defined in test_helper.exs) so tests
# never hit the network. The contract lives in ExAthena.Search.
config :ex_athena, :search, adapter: ExAthena.Search.Mock

# Settings are persisted to the user's home by default. A test that saves must
# never touch it — one that did wrote a real settings.json and silently capped
# a live run's report size. Pin the path here so no ordering or setup mistake
# can reach the real file.
config :ex_athena, :settings_path, Path.join(System.tmp_dir!(), "ex_athena_test_settings.json")

# Web UI endpoint for route-level LiveView tests (test/ex_athena/web/*).
# Phoenix.LiveViewTest drives the endpoint in-process; the HTTP server is
# never started. Mirrors the config `mix athena.web` builds at runtime
# (Mix.Tasks.AthenaWeb.endpoint_config/1) with a fixed test secret.
config :ex_athena, ExAthena.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost", port: 4000],
  secret_key_base: String.duplicate("test-secret-key-base-0123456789", 4),
  live_view: [signing_salt: "ex_athena_lv_test_salt"],
  pubsub_server: ExAthena.PubSub,
  render_errors: [formats: [html: ExAthena.Web.ErrorHTML], layout: false],
  server: false
