import Config

# Disable LSP supervisor during tests so individual test cases can start
# their own isolated supervision trees via start_supervised!/1.
config :ex_athena, enable_lsp: false

# Disable sweepers that are not needed during tests.
config :ex_athena, enable_worktree_sweeper: false
config :ex_athena, enable_checkpoint_sweeper: false
