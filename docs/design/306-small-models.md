# Where helpers start to work on a local model

ExAthena issue 321. Measured 2026-11-27 with `bench/small_models.exs` on
the owner's Mac, Ollama, helpers switched on for every model, the finish
checks off, three runs per model. Each run gets the same three-step task in
a fresh four-file project: add `farewell/1` to `lib/greeter.ex`, add its
test, and list every public function in `lib/`, sending a helper for the
list.

The default `chat.small_model_below_b` is 8: below 8 billion parameters a
model starts without helpers and is told to keep a to-do list.

## What each model did

"Helpers sent" counts `spawn_agent` calls, and "came back" counts those whose
result was not an error; the script does not read the report itself.

- **qwen2.5-coder:14b (14.8B).** Helpers sent per run: 2, 3 and 1, every one
  back without an error. It wrote a to-do list in 3 of 3 runs, and made the
  change and its test in 2 of 3; the other run stopped on the no-progress
  guard. Before this issue's fix to fenced tool calls, it made the change in
  0 of 4 runs, and called no tool in the one run that counted calls: it
  writes each call as one `json` code block.
- **qwen3.5 (9.7B, size from Ollama).** Helpers sent per run: 1, 1 and 1, each
  back without an error. It made the change and its test in 3 of 3, and wrote
  no to-do list in any run, although it was told to (it counted as small at
  the trial default of 10).
- **gemma4:e4b (4B effective, 8B total).** Helpers sent per run: 0, 3 and 0,
  the 3 back without an error. It made the change and its test in 3 of 3.
  Two of the three runs then ended on a stop guard (repeated mistakes, no
  progress).
- **llama3.2:3b (3.2B).** Helpers sent per run: 0, 0 and 0. It made the change
  in 0 of 3 runs; two runs answered in text after one tool call.

Helpers were sent in every run from 9.7B up, in one run of three at 4B, and
never at 3B. The default of 8 keeps helpers for the 9.7B and 14.8B models and
switches them off for the 4B and 3B ones.

## Limits of this measurement

- qwen2.5-coder:7b, the size the issue names, was not installed, so no 7B
  model was run; 8 sits between the 4B and the 9.7B results.
- Three runs per model. The load average ran 6 to 19 on 15 cores during the
  runs, which changes timings, not the counts above.
- "Made the change" is a text match after the run: `def farewell` in
  `lib/greeter.ex` and `farewell` in the test file. Nothing compiles or runs
  them, and the list of public functions in the answer is not scored. The
  "to-do list" count reads a successful `todo_write` call and does not judge
  the list.
