import Config

# Compaction trigger for a local Qwen3.6-35B-A3B served at 128k.
#
# This is deliberately LATE. Compaction is what causes repetition loops in an
# agent run: ObservationMask replaces all but the last 5 tool results with
# "[output cleared…]", so the record of what the agent already did disappears
# and it does it again. Compact as late as the window safely allows.
#
# `Compactor.estimate_tokens/2` counts bytes/4, which under-reports code and
# JSON tool output by roughly 20-25%. So the real 131_072 ceiling is hit at
# around 100k *estimated* tokens. 0.75 -> 98_304 estimated puts compaction
# just before the wall rather than in the middle of the run.
#
# If prompts still overflow, lower this before touching anything else.
# config :ex_athena, :compactor, compact_at: 0.75
config :logger, level: :debug
