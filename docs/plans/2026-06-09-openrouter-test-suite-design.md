# Sidecar OpenRouter Test Suite — Design

**Date:** 2026-06-09
**Status:** Approved

## Problem

The only regression check today is `skills/sidecar/scripts/test.sh` — a live smoke
test that needs a real OpenRouter key, costs money per run, depends on whichever
model is configured, and cannot simulate failures. Every bug the proxy patches
guard against (B1–B4, C1–C3, P1–P2) was found in production-like use. The
translation layer (534-line `anthropic-proxy-patched.mjs`) has no tests of its
own. A second lesson from history: Gemini's lenient adapter masked the C1
malformed-`tool_calls` bug that strict providers (DeepSeek, OpenAI) rejected —
so testing only the configured default model gives false confidence.

## Decisions

| Decision | Choice |
|---|---|
| Architecture | Two-tier: mock-based integration suite + small live matrix |
| Toolchain | `node --test` (Node ≥20 built-in runner), zero new dependencies |
| Scope | Proxy (deep) + bash script smoke tests; existing `test.sh` untouched |
| Live matrix | 3 fixed cheap models spanning strictness tiers: Gemini Flash (lenient), DeepSeek (strict), cheap OpenAI (strict) |
| Test target | `bundle.cjs` (ship artifact) by default; `SIDECAR_TEST_ENTRY` overrides to the patched `.mjs` for debug |

## Layout

```
tests/
├── helpers/
│   ├── fake-openrouter.mjs    # programmable mock upstream (node:http)
│   └── proxy-harness.mjs      # spawn/await/kill the real proxy child process
├── integration/               # Tier 1 — no network, no key
│   ├── request-translation.test.mjs
│   ├── response-nonstreaming.test.mjs
│   ├── response-streaming.test.mjs
│   ├── error-resilience.test.mjs
│   └── scripts.test.mjs
├── live/
│   └── matrix.sh              # Tier 2 — real OpenRouter, 3-provider matrix
└── run-integration.sh         # node --test tests/integration/
```

Tier 1 is true integration testing: the real proxy binary runs as a child
process pointed at the fake upstream via `ANTHROPIC_PROXY_BASE_URL`, with real
HTTP on both sides. Tests use ephemeral ports so suites can run in parallel.

## Tier 1a — Fake OpenRouter

A ~100-line `node:http` server, programmable per test:

- **Captures** each request (headers + parsed JSON body) so tests assert on
  what the proxy actually sent upstream — this is how translation correctness
  is verified.
- **Responds** from canned fixtures: non-streaming chat-completion JSON,
  scripted SSE chunk sequences (including lines split across TCP chunks), or
  fault injections (HTTP 401/429/500, garbage `data:` lines, mid-stream error
  payloads, indefinite hang).

## Tier 1b — Integration test inventory (~35 cases)

### Request translation (assert on captured upstream body)
- `system` array → `role:system` messages; string and array user content
- **C1 regression:** `tool_use` → `{id, type:'function', function:{name, arguments:<JSON string>}}` — id/type top-level, arguments a JSON-encoded string
- **C2 regression:** mixed user turn (text + tool_result) emits `role:tool` messages *before* the user-text message (OpenAI adjacency requirement)
- `tool_result` with array content → stringified
- Tools mapping: `input_schema` → `parameters`; `BatchTool` filtered out; `format:'uri'` stripped recursively (incl. `anyOf`/`allOf`/`oneOf`/`items`)
- Model routing: `payload.thinking` → `REASONING_MODEL`, else `COMPLETION_MODEL`; client-sent model ignored
- **B4:** `SIDECAR_STREAMING=false` forces `stream:false`; otherwise follows `payload.stream === true`
- Temperature default 1; `max_tokens` passthrough

### Non-streaming response translation
- Text content → text block; `id` rewrite `chatcmpl` → `msg`
- **C3:** upstream `reasoning` field → leading `thinking` block
- **B3:** `content:null` + tool_calls → no text block, valid response, no crash
- **P1:** malformed JSON in `tool_calls.function.arguments` → `input:{}`, no crash
- `finish_reason` mapping: `tool_calls`→`tool_use`, `stop`→`end_turn`, `length`→`max_tokens`
- Usage mapping from `data.usage`; fallback word-count path with null-content guard

### Streaming response translation
- Full SSE sequence: `message_start` → `ping` → `content_block_start/delta/stop` → `message_delta` (correct `stop_reason` + usage) → `message_stop`
- Text deltas accumulate in order; `delta.reasoning` → `thinking_delta`
- Tool-call deltas → `content_block_start` (tool_use) + incremental `input_json_delta`; multiple parallel tool calls keep distinct indices
- `stop_reason: tool_use` when any tool call encountered, else `end_turn`

### Error resilience
- **B2:** non-JSON `data:` lines mid-stream are skipped; stream completes normally
- **B1:** upstream error *after* streaming has started → proxy ends the stream cleanly and the **process survives** (verified by a successful follow-up request)
- Upstream 401/429/500 on non-streaming → status code + error body passed through
- Sequential survival: 5 requests against one proxy process, all succeed
- **P2:** hung upstream → request aborts at the configured timeout. Requires one
  small proxy change: replace the hardcoded `AbortSignal.timeout(120000)` with
  `Number(process.env.SIDECAR_UPSTREAM_TIMEOUT_MS) || 120000` so the test can
  use a 2-second timeout. Behavior is unchanged when the env var is unset.

### Script smoke tests (temp dirs, no network)
- `_locate.sh`: state-dir discovery and fallback order
- `set-model.sh`: rewrites `COMPLETION_MODEL`/`REASONING_MODEL`, preserves the rest of `.env.local`
- `set-key.sh`: accepts `sk-or-*` via stdin, rejects malformed keys, never echoes the key to stdout
- `setup.sh`: running twice is idempotent (same state, exit 0)

## Tier 2 — Live matrix (`tests/live/matrix.sh`)

For each of the three fixed models, against real OpenRouter through the real
proxy:

1. Simple completion (non-streaming)
2. Two-turn tool-use round trip (C1 probe — strict providers reject malformed `tool_calls`)
3. Mixed text + tool_result user turn (C2 probe — adjacency)
4. Streaming request asserting a well-formed Anthropic SSE event sequence

Plus one `claude` CLI pong check on the configured default model. Key comes from
`.env.local` via `_locate.sh`. Output is a per-model PASS/FAIL grid; exit code
is the failure count. Intended cadence: manual, before tagging a release.
Cost: pennies. `max_tokens` floors at 200 per the reasoning-model lesson
already documented in `test.sh`.

The existing `scripts/test.sh` is unchanged — it remains the in-Cowork,
single-model setup verifier that ships with the plugin.

## Build / packaging

- Add `'tests/*' 'tests'` to `build.sh`'s zip exclusions. The current
  `*/tests/*` pattern does not match a repo-root `tests/` directory.
- No new dependencies. Tier 1 needs Node ≥20 and bash. The test directory is
  dev-only and never ships in the `.plugin`.

## Known gap (accepted)

The `Authorization: Bearer` header cannot be asserted against the fake server:
the proxy attaches it only when `ANTHROPIC_PROXY_BASE_URL` is unset (i.e., real
OpenRouter). The live matrix covers auth implicitly.
