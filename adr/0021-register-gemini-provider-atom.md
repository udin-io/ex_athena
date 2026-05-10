# ADR 1: Register `:gemini` as a first-class provider atom

## Status

Proposed

## Context

ExAthena exposes a small set of provider atoms (`:ollama`, `:openai`, `:openai_compatible`, `:llamacpp`, `:claude`, `:anthropic`, `:mock`, `:req_llm`) that callers can use via `ExAthena.query(..., provider: <atom>)`. Each atom maps in `ExAthena.Config.@builtin_providers` to a backing module — most route to `ExAthena.Providers.ReqLLM`, which delegates to the `req_llm` library. A second map, `@req_llm_provider_tag`, stores the string tag used in `req_llm`'s `"tag:model-id"` model spec (e.g. `:claude` → `"anthropic"`).

`req_llm` already ships full Google Gemini support under the provider tag `"google"` (see `deps/req_llm/lib/req_llm/providers/google.ex`). Today, callers wanting Gemini must use the lower-level form `provider: :req_llm, model: "google:gemini-2.5-flash"`, which is awkward for downstream apps that swap providers by atom (e.g. `udin-io/udin_code`'s `ModelProvider`).

Gemini is a hosted, authenticated API — unlike Ollama/llama.cpp it is not OpenAI-compatible, does not need a custom `base_url`, and must not be added to `@local_openai_compatible_backends` (which exists to suppress req_llm's API-key requirement for unauthenticated local servers).

## Decision

1. Add `gemini: ExAthena.Providers.ReqLLM` to `ExAthena.Config.@builtin_providers`.
2. Add `gemini: "google"` to `ExAthena.Config.@req_llm_provider_tag`. The tag string `"google"` matches `req_llm`'s adapter id.
3. Do NOT add `:gemini` to `@local_openai_compatible_backends` — Gemini is hosted and authenticated.
4. Update the "Known providers" `@moduledoc` table in `lib/ex_athena/config.ex`, the provider list in `lib/ex_athena.ex`, the provider tables in `README.md` and `guides/providers.md`, and bump `mix.exs` `@version` from `0.6.0` to `0.7.0` (additive, no breakage). Add a `## 0.7.0` entry to `CHANGELOG.md`.
5. Tests: TDD unit tests in `test/ex_athena/config_test.exs` against `Config.pop_provider!/1` (the actual public function — the ticket's reference to `expand_options/1` is incorrect, see Consequences). A live test in `test/ex_athena/providers/gemini_live_test.exs` tagged `@moduletag :external` exercises end-to-end inference; CI excludes `:external` by default.

## Consequences

**Positive**

- Callers can write `provider: :gemini, model: "gemini-2.5-flash"` cleanly, on par with `:claude` / `:openai`.
- No new code paths, no hand-rolled HTTP — req_llm handles transport, auth, streaming, tool-calls, and structured output for Gemini.
- Additive change, semver-minor bump; no breakage for existing callers.

**Neutral / clarifying**

- The ticket asks for an assertion against `Config.expand_options/1`, which does not exist. The implementation tests `Config.pop_provider!/1` instead (the function `ExAthena.query/2` actually calls). Documented in the PR.
- The ticket also cites `%ExAthena.Result{}`; the canonical struct is `%ExAthena.Response{}`. The live test uses the real struct.

**Negative**

- The `:gemini` atom is now resolved at compile time via the module attribute. Downstream code that introspected `Config.builtin_providers/0` will see one extra key — no callers depend on the exact set, but worth scanning for `Map.keys(builtin_providers)` matchers.
- Tool-calling parity across providers is not part of this ticket; Gemini's tool-calling behaviour through req_llm is exercised only by the live smoke test, not a parity matrix. Tracked separately if needed.
