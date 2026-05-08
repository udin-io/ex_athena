# ADR 1: No Architectural Decision Required

## Status

N/A

## Context

Two source files (`lib/ex_athena/providers/req_llm.ex` and `test/ex_athena/structured_output_test.exs`) failed `mix format --check-formatted` due to pre-existing whitespace/style issues on main. No logic or architecture changes are involved.

## Decision

Run `mix format` on both files. This is a pure code-style fix with no architectural implications.

## Consequences

- Both files pass `mix format --check-formatted`.
- CI format checks no longer fail for these files.
- Zero functional or behavioural changes.
