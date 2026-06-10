# OpenRouter Test Suite Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a two-tier test suite — a zero-dependency `node --test` integration suite that runs the real proxy against a fake OpenRouter server, plus a 3-provider live matrix script — per the approved design in `docs/plans/2026-06-09-openrouter-test-suite-design.md`.

**Architecture:** Tier 1 spawns the shipped proxy artifact (`skills/sidecar/proxy/bundle.cjs`) as a child process pointed at a programmable in-process `node:http` fake upstream via `ANTHROPIC_PROXY_BASE_URL`, asserting on (a) the request bodies the proxy sends upstream and (b) the Anthropic-format responses it returns. Script smoke tests drive the bash scripts in temp HOMEs with stubbed PATH binaries. Tier 2 is a bash matrix against real OpenRouter.

**Tech Stack:** Node ≥20 built-in test runner (`node --test`), `node:http`, `node:net`, `node:child_process` (`execFileSync` only — never `exec`/`execSync` with interpolated strings), bash. **No new dependencies.**

**Key background for the implementer:**
- The proxy source is `skills/sidecar/proxy/anthropic-proxy-patched.mjs`; what ships is `bundle.cjs`, built by `build.sh` (esbuild bundling `wrapper.mjs` → patched proxy). If you modify the `.mjs`, you MUST rerun `bash build.sh` before bundle-targeting tests see the change.
- Proxy env contract: `PORT` (listen port), `ANTHROPIC_PROXY_BASE_URL` (upstream base; proxy fetches `<base>/v1/chat/completions`; setting it also disables the Authorization header), `COMPLETION_MODEL`, `REASONING_MODEL`, `SIDECAR_STREAMING` (`false` forces non-streaming; anything else honors `payload.stream === true`).
- Bug codes referenced in test names (B1–B4, C1–C3, P1–P2) are documented in the header comment of `anthropic-proxy-patched.mjs` — read it first.
- Run all commands from the repo root: `/Users/john_renaldi/Documents/ClaudeCowork/sidecar-plugin`.

---

### Task 1: Build exclusion + test runner skeleton

**Files:**
- Modify: `build.sh:54-63` (zip exclusions)
- Create: `tests/run-integration.sh`

**Step 1: Add `tests/` to the zip exclusions in build.sh**

In the `zip -qr` block, after the line `'skills/sidecar/proxy/node_modules' \`, add:

```bash
       'tests/*' 'tests' \
       'docs/*' 'docs' \
```

(The existing `*/tests/*` pattern does not match a repo-root `tests/` dir — zip `-x` patterns need the leading component. `docs/` is excluded for the same reason: plans shouldn't ship in the plugin.)

**Step 2: Create the runner**

```bash
#!/usr/bin/env bash
# run-integration.sh — Tier 1: mock-based integration tests. No network, no key.
# Usage: bash tests/run-integration.sh [extra node --test args]
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
exec node --test --test-concurrency=1 "$@" "$DIR/integration/"
```

(`--test-concurrency=1`: each test file spawns proxy child processes; serial keeps port/process management simple.)

**Step 3: Verify**

Run: `mkdir -p tests/integration && chmod +x tests/run-integration.sh && bash tests/run-integration.sh; echo "exit=$?"`
Expected: runs with 0 tests (or a "no test files" note) — fine at this stage.

Run: `bash build.sh && unzip -Z1 ../sidecar.plugin | grep -c '^tests/'; true`
Expected: `0` (no tests/ entries in the archive).

**Step 4: Commit**

```bash
git add build.sh tests/run-integration.sh
git commit -m "test: add integration runner; exclude tests/ and docs/ from plugin zip"
```

---

### Task 2: Fake OpenRouter helper

**Files:**
- Create: `tests/helpers/fake-openrouter.mjs`

**Step 1: Write the helper (complete code)**

```js
// fake-openrouter.mjs — programmable mock of OpenRouter's
// /v1/chat/completions endpoint. Captures every request; responds from a
// FIFO queue of programmed responders (falls back to a default).
import http from 'node:http'

export function jsonResponder(obj, status = 200) {
  return (req, res) => {
    res.writeHead(status, { 'content-type': 'application/json' })
    res.end(JSON.stringify(obj))
  }
}

// chunks: array of raw strings written sequentially to the socket.
// Caller is responsible for SSE framing ("data: {...}\n\n", "data: [DONE]\n\n").
export function sseResponder(chunks, { delayMs = 5 } = {}) {
  return async (req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const c of chunks) {
      res.write(c)
      await new Promise(r => setTimeout(r, delayMs))
    }
    res.end()
  }
}

export function hangResponder() {
  return () => { /* never respond; socket stays open */ }
}

// Standard non-streaming completion fixture.
export function completion({ content = 'ok', reasoning, tool_calls,
                             finish_reason = 'stop', usage, id = 'chatcmpl-test123', model = 'fake/model' } = {}) {
  return {
    id, model, object: 'chat.completion',
    choices: [{ index: 0, finish_reason,
      message: { role: 'assistant', content, ...(reasoning ? { reasoning } : {}), ...(tool_calls ? { tool_calls } : {}) } }],
    usage: usage === null ? undefined : (usage ?? { prompt_tokens: 10, completion_tokens: 5 }),
  }
}

// SSE data line for a streaming delta.
export function sseDelta(delta, extra = {}) {
  return `data: ${JSON.stringify({ choices: [{ index: 0, delta }], ...extra })}\n\n`
}

export async function startFakeOpenRouter() {
  const requests = []   // { method, url, headers, body }
  const queue = []      // responder fns, FIFO
  const server = http.createServer((req, res) => {
    let raw = ''
    req.on('data', d => { raw += d })
    req.on('end', () => {
      let body = null
      try { body = JSON.parse(raw) } catch { body = raw }
      requests.push({ method: req.method, url: req.url, headers: req.headers, body })
      const responder = queue.shift() ?? jsonResponder(completion())
      responder(req, res)
    })
  })
  await new Promise(r => server.listen(0, '127.0.0.1', r))
  const port = server.address().port
  return {
    port,
    url: `http://127.0.0.1:${port}`,
    requests,
    lastRequest: () => requests[requests.length - 1],
    respondWith: (...responders) => queue.push(...responders),
    close: () => new Promise(r => { server.closeAllConnections?.(); server.close(r) }),
  }
}
```

**Step 2: Smoke-check the helper**

Run:
```bash
node -e "
import('./tests/helpers/fake-openrouter.mjs').then(async m => {
  const f = await m.startFakeOpenRouter()
  const r = await fetch(f.url + '/v1/chat/completions', { method: 'POST', body: JSON.stringify({hi:1}) })
  const j = await r.json()
  console.assert(j.choices[0].message.content === 'ok', 'default fixture')
  console.assert(f.lastRequest().body.hi === 1, 'captured body')
  await f.close(); console.log('helper OK')
})"
```
Expected: `helper OK`

**Step 3: Commit**

```bash
git add tests/helpers/fake-openrouter.mjs
git commit -m "test: add programmable fake OpenRouter upstream"
```

---

### Task 3: Proxy harness helper

**Files:**
- Create: `tests/helpers/proxy-harness.mjs`

**Step 1: Write the helper (complete code)**

```js
// proxy-harness.mjs — spawn the real proxy as a child process against a fake
// upstream, plus client helpers for posting /v1/messages and parsing SSE.
import { spawn } from 'node:child_process'
import net from 'node:net'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
// Default: test the ship artifact. Override with SIDECAR_TEST_ENTRY to point
// at proxy/anthropic-proxy-patched.mjs for fast debug loops (no rebuild).
const ENTRY = process.env.SIDECAR_TEST_ENTRY
  || path.join(REPO_ROOT, 'skills/sidecar/proxy/bundle.cjs')

async function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer()
    s.listen(0, '127.0.0.1', () => {
      const p = s.address().port
      s.close(() => resolve(p))
    })
    s.on('error', reject)
  })
}

async function waitForListen(port, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const up = await new Promise(resolve => {
      const sock = net.connect({ port, host: '127.0.0.1' }, () => { sock.destroy(); resolve(true) })
      sock.on('error', () => resolve(false))
    })
    if (up) return
    await new Promise(r => setTimeout(r, 50))
  }
  throw new Error(`proxy did not listen on ${port} within ${timeoutMs}ms`)
}

export async function startProxy({ upstreamUrl, env = {} }) {
  const port = await freePort()
  const proc = spawn(process.execPath, [ENTRY], {
    env: {
      ...process.env,
      PORT: String(port),
      ANTHROPIC_PROXY_BASE_URL: upstreamUrl,
      COMPLETION_MODEL: 'fake/completion-model',
      REASONING_MODEL: 'fake/reasoning-model',
      ...env,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let logs = ''
  proc.stdout.on('data', d => { logs += d })
  proc.stderr.on('data', d => { logs += d })
  await waitForListen(port)
  return {
    port,
    url: `http://127.0.0.1:${port}`,
    proc,
    alive: () => proc.exitCode === null,
    logs: () => logs,
    stop: () => { proc.kill('SIGKILL') },
  }
}

export async function postMessages(proxyUrl, payload) {
  const res = await fetch(`${proxyUrl}/v1/messages`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'anthropic-version': '2023-06-01' },
    body: JSON.stringify(payload),
  })
  const text = await res.text()
  let json = null
  try { json = JSON.parse(text) } catch { /* SSE or error text */ }
  return { status: res.status, text, json }
}

// Parse an Anthropic SSE response body into [{ event, data }].
export function parseSSE(text) {
  return text.split('\n\n').filter(b => b.trim()).map(block => {
    const event = (block.match(/^event: (.+)$/m) || [])[1]
    const dataRaw = (block.match(/^data: (.+)$/m) || [])[1]
    let data = null
    try { data = JSON.parse(dataRaw) } catch { data = dataRaw }
    return { event, data }
  }).filter(e => e.event)
}

// Minimal valid Anthropic payload with overrides.
export function anthropicPayload(overrides = {}) {
  return { model: 'ignored-by-proxy', max_tokens: 100,
           messages: [{ role: 'user', content: 'hello' }], ...overrides }
}
```

**Step 2: Smoke-check harness + fake end to end**

Run:
```bash
node -e "
Promise.all([import('./tests/helpers/fake-openrouter.mjs'), import('./tests/helpers/proxy-harness.mjs')]).then(async ([f, h]) => {
  const fake = await f.startFakeOpenRouter()
  const proxy = await h.startProxy({ upstreamUrl: fake.url })
  const r = await h.postMessages(proxy.url, h.anthropicPayload())
  console.assert(r.status === 200 && r.json.content[0].text === 'ok', JSON.stringify(r))
  proxy.stop(); await fake.close(); console.log('harness OK')
})"
```
Expected: `harness OK`. If the proxy never listens, check `bundle.cjs` exists (`bash build.sh`).

**Step 3: Commit**

```bash
git add tests/helpers/proxy-harness.mjs
git commit -m "test: add proxy child-process harness and SSE client helpers"
```

---

### Task 4: Request-translation integration tests

**Files:**
- Create: `tests/integration/request-translation.test.mjs`

These assert on `fake.lastRequest().body` — the OpenAI payload the proxy actually sent. One proxy + one fake per file (started in `before`, killed in `after`); each test enqueues its own responder when the default isn't enough.

**Step 1: Write the tests (complete code)**

```js
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { startFakeOpenRouter } from '../helpers/fake-openrouter.mjs'
import { startProxy, postMessages, anthropicPayload } from '../helpers/proxy-harness.mjs'

let fake, proxy
before(async () => {
  fake = await startFakeOpenRouter()
  proxy = await startProxy({ upstreamUrl: fake.url })
})
after(async () => { proxy.stop(); await fake.close() })

test('system array becomes role:system messages', async () => {
  await postMessages(proxy.url, anthropicPayload({
    system: [{ type: 'text', text: 'be terse' }],
  }))
  const sent = fake.lastRequest().body
  assert.deepEqual(sent.messages[0], { role: 'system', content: 'be terse' })
})

test('string user content passes through', async () => {
  await postMessages(proxy.url, anthropicPayload({ messages: [{ role: 'user', content: 'plain' }] }))
  assert.deepEqual(fake.lastRequest().body.messages, [{ role: 'user', content: 'plain' }])
})

test('array user content joins text blocks', async () => {
  await postMessages(proxy.url, anthropicPayload({
    messages: [{ role: 'user', content: [{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }] }],
  }))
  assert.equal(fake.lastRequest().body.messages[0].content, 'ab')
})

test('C1: tool_use maps to correct OpenAI tool_calls shape', async () => {
  await postMessages(proxy.url, anthropicPayload({
    messages: [
      { role: 'user', content: 'calc' },
      { role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_1', name: 'calc', input: { expr: '2+2' } }] },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content: '4' }] },
    ],
  }))
  const asst = fake.lastRequest().body.messages.find(m => m.role === 'assistant')
  assert.deepEqual(asst.tool_calls, [{
    id: 'toolu_1', type: 'function',
    function: { name: 'calc', arguments: JSON.stringify({ expr: '2+2' }) },   // arguments is a STRING
  }])
  assert.equal(typeof asst.tool_calls[0].function.arguments, 'string')
})

test('C2: tool_result emitted before user text, adjacent to assistant tool_calls', async () => {
  await postMessages(proxy.url, anthropicPayload({
    messages: [
      { role: 'user', content: 'ls' },
      { role: 'assistant', content: [
        { type: 'text', text: 'checking' },
        { type: 'tool_use', id: 'toolu_2', name: 'bash', input: { command: 'ls' } }] },
      { role: 'user', content: [
        { type: 'tool_result', tool_use_id: 'toolu_2', content: 'file1' },
        { type: 'text', text: '<system-reminder>be brief</system-reminder>' }] },
    ],
  }))
  const sent = fake.lastRequest().body.messages
  const asstIdx = sent.findIndex(m => m.role === 'assistant')
  assert.equal(sent[asstIdx + 1].role, 'tool')                    // adjacency
  assert.equal(sent[asstIdx + 1].tool_call_id, 'toolu_2')
  assert.equal(sent[asstIdx + 1].content, 'file1')
  assert.equal(sent[asstIdx + 2].role, 'user')                    // reminder text AFTER
})

test('tool_result array content is stringified', async () => {
  await postMessages(proxy.url, anthropicPayload({
    messages: [
      { role: 'user', content: 'q' },
      { role: 'assistant', content: [{ type: 'tool_use', id: 't3', name: 'f', input: {} }] },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't3',
        content: [{ type: 'text', text: 'part1 ' }, { type: 'text', text: 'part2' }] }] },
    ],
  }))
  const toolMsg = fake.lastRequest().body.messages.find(m => m.role === 'tool')
  assert.equal(toolMsg.content, 'part1 part2')
})

test('tools map input_schema->parameters, filter BatchTool, strip format:uri recursively', async () => {
  await postMessages(proxy.url, anthropicPayload({
    tools: [
      { name: 'BatchTool', description: 'x', input_schema: { type: 'object' } },
      { name: 'fetcher', description: 'gets a url', input_schema: {
          type: 'object',
          properties: { url: { type: 'string', format: 'uri' },
                        alt: { anyOf: [{ type: 'string', format: 'uri' }, { type: 'null' }] } } } },
    ],
  }))
  const sent = fake.lastRequest().body
  assert.equal(sent.tools.length, 1)
  const fn = sent.tools[0]
  assert.equal(fn.type, 'function')
  assert.equal(fn.function.name, 'fetcher')
  assert.deepEqual(fn.function.parameters.properties.url, { type: 'string' })
  assert.deepEqual(fn.function.parameters.properties.alt.anyOf[0], { type: 'string' })
})

test('model routing: thinking->REASONING_MODEL, default->COMPLETION_MODEL, client model ignored', async () => {
  await postMessages(proxy.url, anthropicPayload({ model: 'claude-whatever' }))
  assert.equal(fake.lastRequest().body.model, 'fake/completion-model')
  await postMessages(proxy.url, anthropicPayload({ thinking: { type: 'enabled', budget_tokens: 100 } }))
  assert.equal(fake.lastRequest().body.model, 'fake/reasoning-model')
})

test('B4: stream follows payload.stream when SIDECAR_STREAMING unset', async () => {
  await postMessages(proxy.url, anthropicPayload())                      // no stream field
  assert.equal(fake.lastRequest().body.stream, false)
})

test('max_tokens and default temperature forwarded', async () => {
  await postMessages(proxy.url, anthropicPayload({ max_tokens: 321 }))
  const sent = fake.lastRequest().body
  assert.equal(sent.max_tokens, 321)
  assert.equal(sent.temperature, 1)
  await postMessages(proxy.url, anthropicPayload({ temperature: 0.2 }))
  assert.equal(fake.lastRequest().body.temperature, 0.2)
})
```

**Step 2: Run and verify the suite passes against the current bundle**

Run: `bash tests/run-integration.sh`
Expected: all tests in this file PASS (the patches already exist — these are regression locks; the "failing first" stage was the historical bugs themselves). If any FAIL, the bundle is stale: run `bash build.sh` and rerun. A failure after rebuild is a real finding — stop and diagnose, do not adjust the assertion to match.

**Step 3: Commit**

```bash
git add tests/integration/request-translation.test.mjs
git commit -m "test: lock request translation (C1, C2, tools mapping, model routing, B4)"
```

---

### Task 5: B4 forced-off variant (separate proxy env)

**Files:**
- Modify: `tests/integration/request-translation.test.mjs` (append)

**Step 1: Append a test that boots its own proxy with `SIDECAR_STREAMING=false`**

```js
test('B4: SIDECAR_STREAMING=false forces stream:false even when client asks to stream', async () => {
  const fake2 = await startFakeOpenRouter()
  const proxy2 = await startProxy({ upstreamUrl: fake2.url, env: { SIDECAR_STREAMING: 'false' } })
  try {
    await postMessages(proxy2.url, anthropicPayload({ stream: true }))
    assert.equal(fake2.lastRequest().body.stream, false)
  } finally { proxy2.stop(); await fake2.close() }
})
```

**Step 2: Run** — `bash tests/run-integration.sh` → PASS.

**Step 3: Commit** — `git add -u && git commit -m "test: B4 forced non-streaming override"`

---

### Task 6: Non-streaming response translation tests

**Files:**
- Create: `tests/integration/response-nonstreaming.test.mjs`

**Step 1: Write the tests (complete code)**

```js
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { startFakeOpenRouter, jsonResponder, completion } from '../helpers/fake-openrouter.mjs'
import { startProxy, postMessages, anthropicPayload } from '../helpers/proxy-harness.mjs'

let fake, proxy
before(async () => {
  fake = await startFakeOpenRouter()
  proxy = await startProxy({ upstreamUrl: fake.url })
})
after(async () => { proxy.stop(); await fake.close() })

test('text content becomes a text block; id chatcmpl->msg; stop->end_turn', async () => {
  fake.respondWith(jsonResponder(completion({ content: 'hi there', id: 'chatcmpl-abc' })))
  const r = await postMessages(proxy.url, anthropicPayload())
  assert.equal(r.status, 200)
  assert.deepEqual(r.json.content, [{ type: 'text', text: 'hi there' }])
  assert.equal(r.json.id, 'msg-abc')
  assert.equal(r.json.stop_reason, 'end_turn')
  assert.equal(r.json.type, 'message')
  assert.equal(r.json.role, 'assistant')
})

test('C3: upstream reasoning field surfaces as leading thinking block', async () => {
  fake.respondWith(jsonResponder(completion({ content: 'answer', reasoning: 'chain of thought' })))
  const r = await postMessages(proxy.url, anthropicPayload())
  assert.deepEqual(r.json.content[0], { type: 'thinking', thinking: 'chain of thought' })
  assert.deepEqual(r.json.content[1], { type: 'text', text: 'answer' })
})

test('B3: content:null with tool_calls -> no text block, valid tool_use response', async () => {
  fake.respondWith(jsonResponder(completion({
    content: null, finish_reason: 'tool_calls',
    tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'calc', arguments: '{"expr":"2+2"}' } }],
  })))
  const r = await postMessages(proxy.url, anthropicPayload())
  assert.equal(r.status, 200)
  assert.deepEqual(r.json.content, [{ type: 'tool_use', id: 'call_1', name: 'calc', input: { expr: '2+2' } }])
  assert.equal(r.json.stop_reason, 'tool_use')
})

test('P1: malformed tool_call arguments JSON -> input {} without crashing', async () => {
  fake.respondWith(jsonResponder(completion({
    content: null, finish_reason: 'tool_calls',
    tool_calls: [{ id: 'call_2', type: 'function', function: { name: 'f', arguments: '{not json' } }],
  })))
  const r = await postMessages(proxy.url, anthropicPayload())
  assert.deepEqual(r.json.content[0].input, {})
  assert.ok(proxy.alive())
})

test('finish_reason length -> max_tokens', async () => {
  fake.respondWith(jsonResponder(completion({ finish_reason: 'length' })))
  const r = await postMessages(proxy.url, anthropicPayload())
  assert.equal(r.json.stop_reason, 'max_tokens')
})

test('usage mapped from upstream usage', async () => {
  fake.respondWith(jsonResponder(completion({ usage: { prompt_tokens: 42, completion_tokens: 7 } })))
  const r = await postMessages(proxy.url, anthropicPayload())
  assert.deepEqual(r.json.usage, { input_tokens: 42, output_tokens: 7 })
})

test('B3 usage guard: missing usage + null content does not crash word-count fallback', async () => {
  fake.respondWith(jsonResponder(completion({
    content: null, usage: null, finish_reason: 'tool_calls',
    tool_calls: [{ id: 'c', type: 'function', function: { name: 'f', arguments: '{}' } }],
  })))
  const r = await postMessages(proxy.url, anthropicPayload())
  assert.equal(r.status, 200)
  assert.ok(proxy.alive())
})
```

**Step 2: Run** — `bash tests/run-integration.sh` → all PASS (same regression-lock logic as Task 4).
Note on the id assertion: the proxy does `data.id.replace('chatcmpl', 'msg')` — `chatcmpl-abc` → `msg-abc`. If this fails, print `r.json.id` before changing anything.

**Step 3: Commit** — `git add tests/integration/response-nonstreaming.test.mjs && git commit -m "test: lock non-streaming response translation (B3, C3, P1, stop reasons)"`

---

### Task 7: Streaming response translation tests

**Files:**
- Create: `tests/integration/response-streaming.test.mjs`

Streaming requests need `stream: true` in the payload AND an SSE responder on the fake.

**Step 1: Write the tests (complete code)**

```js
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { startFakeOpenRouter, sseResponder, sseDelta } from '../helpers/fake-openrouter.mjs'
import { startProxy, postMessages, parseSSE, anthropicPayload } from '../helpers/proxy-harness.mjs'

let fake, proxy
before(async () => {
  fake = await startFakeOpenRouter()
  proxy = await startProxy({ upstreamUrl: fake.url })
})
after(async () => { proxy.stop(); await fake.close() })

const DONE = 'data: [DONE]\n\n'

test('text stream: full Anthropic SSE event sequence in order', async () => {
  fake.respondWith(sseResponder([
    sseDelta({ content: 'Hel' }),
    sseDelta({ content: 'lo' }, { usage: { prompt_tokens: 3, completion_tokens: 2 } }),
    DONE,
  ]))
  const r = await postMessages(proxy.url, anthropicPayload({ stream: true }))
  const events = parseSSE(r.text)
  const names = events.map(e => e.event)
  assert.deepEqual(names, ['message_start', 'ping', 'content_block_start',
    'content_block_delta', 'content_block_delta', 'content_block_stop',
    'message_delta', 'message_stop'])
  const deltas = events.filter(e => e.event === 'content_block_delta').map(e => e.data.delta.text)
  assert.deepEqual(deltas, ['Hel', 'lo'])
  const md = events.find(e => e.event === 'message_delta')
  assert.equal(md.data.delta.stop_reason, 'end_turn')
  assert.equal(md.data.usage.output_tokens, 2)
})

test('reasoning deltas become thinking_delta events', async () => {
  fake.respondWith(sseResponder([
    sseDelta({ reasoning: 'thinking...' }),
    sseDelta({ content: 'done' }),
    DONE,
  ]))
  const r = await postMessages(proxy.url, anthropicPayload({ stream: true }))
  const events = parseSSE(r.text)
  const kinds = events.filter(e => e.event === 'content_block_delta').map(e => e.data.delta.type)
  assert.deepEqual(kinds, ['thinking_delta', 'text_delta'])
})

test('tool-call stream: content_block_start + incremental input_json_delta; stop_reason tool_use', async () => {
  fake.respondWith(sseResponder([
    sseDelta({ tool_calls: [{ index: 0, id: 'call_s1', function: { name: 'calc', arguments: '{"ex' } }] }),
    sseDelta({ tool_calls: [{ index: 0, function: { arguments: '{"expr":"2+2"}' } }] }),
    DONE,
  ]))
  const r = await postMessages(proxy.url, anthropicPayload({ stream: true }))
  const events = parseSSE(r.text)
  const start = events.find(e => e.event === 'content_block_start')
  assert.equal(start.data.content_block.type, 'tool_use')
  assert.equal(start.data.content_block.name, 'calc')
  const parts = events.filter(e => e.event === 'content_block_delta').map(e => e.data.delta.partial_json)
  assert.equal(parts.join(''), '{"expr":"2+2"}')        // accumulator emits only the new suffix
  assert.equal(events.find(e => e.event === 'message_delta').data.delta.stop_reason, 'tool_use')
})

test('parallel tool calls keep distinct indices and each gets content_block_stop', async () => {
  fake.respondWith(sseResponder([
    sseDelta({ tool_calls: [{ index: 0, id: 'a', function: { name: 'f1', arguments: '{}' } }] }),
    sseDelta({ tool_calls: [{ index: 1, id: 'b', function: { name: 'f2', arguments: '{}' } }] }),
    DONE,
  ]))
  const r = await postMessages(proxy.url, anthropicPayload({ stream: true }))
  const events = parseSSE(r.text)
  const stops = events.filter(e => e.event === 'content_block_stop').map(e => e.data.index).sort()
  assert.deepEqual(stops, [0, 1])
})

test('SSE data line split across two TCP chunks: B2 guard skips fragments, stream finishes', async () => {
  // The proxy splits per-chunk on \n; a line split mid-JSON across chunks is
  // skipped by the B2 guard (known limitation, documented here). A LATER
  // complete event must still come through and the stream must end cleanly.
  fake.respondWith(sseResponder([
    'data: {"choices":[{"index":0,"del',          // broken fragment (skipped by B2)
    'ta":{"content":"lost"}}]}\n\n',              // orphan tail (also skipped)
    sseDelta({ content: 'kept' }),
    DONE,
  ]))
  const r = await postMessages(proxy.url, anthropicPayload({ stream: true }))
  const events = parseSSE(r.text)
  const texts = events.filter(e => e.event === 'content_block_delta').map(e => e.data.delta.text)
  assert.deepEqual(texts, ['kept'])
  assert.ok(events.some(e => e.event === 'message_stop'))
})
```

**Step 2: Run** — `bash tests/run-integration.sh` → PASS.
Note: if the split-chunk test reveals the proxy DOES reassemble across chunks (texts `['lost','kept']`), that's better behavior than documented — update the assertion and the comment, and note it in the commit message.

**Step 3: Commit** — `git add tests/integration/response-streaming.test.mjs && git commit -m "test: lock streaming SSE translation (event order, thinking, tool deltas)"`

---

### Task 8: Parameterize the upstream timeout (TDD — the one real code change)

**Files:**
- Create: `tests/integration/error-resilience.test.mjs` (first test only)
- Modify: `skills/sidecar/proxy/anthropic-proxy-patched.mjs:239`

**Step 1: Write the failing test**

```js
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { startFakeOpenRouter, jsonResponder, sseResponder, sseDelta, hangResponder, completion } from '../helpers/fake-openrouter.mjs'
import { startProxy, postMessages, parseSSE, anthropicPayload } from '../helpers/proxy-harness.mjs'

test('P2: hung upstream aborts at SIDECAR_UPSTREAM_TIMEOUT_MS and returns 500', { timeout: 15_000 }, async () => {
  const fake = await startFakeOpenRouter()
  const proxy = await startProxy({ upstreamUrl: fake.url, env: { SIDECAR_UPSTREAM_TIMEOUT_MS: '1000' } })
  try {
    fake.respondWith(hangResponder())
    const t0 = Date.now()
    const r = await postMessages(proxy.url, anthropicPayload())
    const elapsed = Date.now() - t0
    assert.equal(r.status, 500)
    assert.ok(elapsed < 10_000, `aborted in ${elapsed}ms (must be ~1s, far below the 120s default)`)
    assert.ok(proxy.alive(), 'proxy must survive the abort')
  } finally { proxy.stop(); await fake.close() }
})
```

**Step 2: Run to verify it fails**

Run: `node --test tests/integration/error-resilience.test.mjs`
Expected: FAIL — the env var isn't honored yet, so the request waits on the 120s default and the test's 15s timeout kills it.

**Step 3: Make the timeout configurable**

In `anthropic-proxy-patched.mjs`, replace line 239:

```js
      signal: AbortSignal.timeout(120000)
```
with:
```js
      // PATCH P2 (amended): timeout overridable for tests; default unchanged.
      signal: AbortSignal.timeout(Number(process.env.SIDECAR_UPSTREAM_TIMEOUT_MS) || 120000)
```

Also update the P2 line in the file's header comment to mention `SIDECAR_UPSTREAM_TIMEOUT_MS`.

**Step 4: Rebuild the bundle and rerun**

Run: `bash build.sh && node --test tests/integration/error-resilience.test.mjs`
Expected: PASS in ~1–2s.

**Step 5: Commit**

```bash
git add skills/sidecar/proxy/anthropic-proxy-patched.mjs tests/integration/error-resilience.test.mjs
# NOTE: bundle.cjs is gitignored by design — rebuild locally with build.sh, never commit it.
git commit -m "feat: make upstream timeout configurable via SIDECAR_UPSTREAM_TIMEOUT_MS + test"
```

---

### Task 9: Remaining error-resilience tests

**Files:**
- Modify: `tests/integration/error-resilience.test.mjs` (append)

**Step 1: Append the tests (complete code)**

```js
test('B2: garbage data lines mid-stream are skipped; stream completes', async () => {
  const fake = await startFakeOpenRouter()
  const proxy = await startProxy({ upstreamUrl: fake.url })
  try {
    fake.respondWith(sseResponder([
      'data: not-json-at-all\n\n',
      ': sse comment heartbeat\n\n',
      sseDelta({ content: 'survived' }),
      'data: [DONE]\n\n',
    ]))
    const r = await postMessages(proxy.url, anthropicPayload({ stream: true }))
    const events = parseSSE(r.text)
    assert.deepEqual(events.filter(e => e.event === 'content_block_delta').map(e => e.data.delta.text), ['survived'])
    assert.ok(events.some(e => e.event === 'message_stop'))
    assert.ok(proxy.alive())
  } finally { proxy.stop(); await fake.close() }
})

test('B1: upstream error AFTER stream start ends stream cleanly; process survives next request', async () => {
  const fake = await startFakeOpenRouter()
  const proxy = await startProxy({ upstreamUrl: fake.url })
  try {
    fake.respondWith(sseResponder([
      sseDelta({ content: 'partial' }),
      'data: {"error":{"message":"upstream exploded"}}\n\n',
    ]))
    const r = await postMessages(proxy.url, anthropicPayload({ stream: true }))
    // Headers were already 200/SSE; the proxy must just end the stream.
    assert.equal(r.status, 200)
    assert.ok(proxy.alive(), 'B1 regression: proxy process died after mid-stream error')
    // Follow-up request must succeed (default fixture).
    const r2 = await postMessages(proxy.url, anthropicPayload())
    assert.equal(r2.status, 200)
    assert.equal(r2.json.content[0].text, 'ok')
  } finally { proxy.stop(); await fake.close() }
})

for (const status of [401, 429, 500]) {
  test(`upstream HTTP ${status} passes through with error body`, async () => {
    const fake = await startFakeOpenRouter()
    const proxy = await startProxy({ upstreamUrl: fake.url })
    try {
      fake.respondWith(jsonResponder({ error: { message: `synthetic ${status}` } }, status))
      const r = await postMessages(proxy.url, anthropicPayload())
      assert.equal(r.status, status)
      assert.match(r.json.error, new RegExp(`synthetic ${status}`))
    } finally { proxy.stop(); await fake.close() }
  })
}

test('proxy survives 5 sequential mixed requests on one process', async () => {
  const fake = await startFakeOpenRouter()
  const proxy = await startProxy({ upstreamUrl: fake.url })
  try {
    for (let i = 0; i < 5; i++) {
      const stream = i % 2 === 1
      if (stream) fake.respondWith(sseResponder([sseDelta({ content: `r${i}` }), 'data: [DONE]\n\n']))
      else fake.respondWith(jsonResponder(completion({ content: `r${i}` })))
      const r = await postMessages(proxy.url, anthropicPayload({ stream }))
      assert.equal(r.status, 200, `request ${i} failed`)
    }
    assert.ok(proxy.alive())
  } finally { proxy.stop(); await fake.close() }
})
```

Note on the status-passthrough assertion: the proxy returns `{ error: <upstream body text> }` where the body text is the raw upstream response — so `r.json.error` is a *string* containing the synthetic message. If the regex fails, log `r.json` to see the actual nesting before adjusting.

**Step 2: Run the full suite** — `bash tests/run-integration.sh` → all files PASS.

**Step 3: Commit** — `git add -u && git commit -m "test: error resilience (B1, B2, status passthrough, sequential survival)"`

---

### Task 10: Script smoke tests

**Files:**
- Create: `tests/integration/scripts.test.mjs`

Strategy: every test gets a fresh temp `HOME` (so `_locate.sh` scans `$HOME/mnt/*`) and a stub `bin/` prepended to `PATH` carrying fake `claude` and fake `curl` (so `setup.sh`/`set-model.sh` run offline). Real `node`/`awk`/`grep` come from the system. **All child processes run via `execFileSync` with argument arrays — never string-interpolated shell commands.**

**Step 1: Write the tests (complete code)**

```js
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const SCRIPTS = path.join(REPO, 'skills/sidecar/scripts')

// Build an isolated env: temp HOME with mnt/<folder>, stub bin on PATH.
function makeEnv({ folders = ['MyFolder'], catalog = ['test/model-a', 'test/model-b'] } = {}) {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-test-')))
  for (const f of folders) fs.mkdirSync(path.join(home, 'mnt', f), { recursive: true })
  const bin = path.join(home, 'bin')
  fs.mkdirSync(bin)
  fs.writeFileSync(path.join(bin, 'claude'), '#!/bin/sh\necho "claude-stub 0.0.0"\n', { mode: 0o755 })
  // curl stub: serves the model catalog for set-model.sh's validation call;
  // reports unreachable (000) for setup.sh's -w "%{http_code}" probe.
  const catalogJson = JSON.stringify({ data: catalog.map(id => ({ id })) })
  fs.writeFileSync(path.join(bin, 'curl'), `#!/bin/sh
case "$*" in
  *http_code*) printf '000' ;;
  *models*) printf '%s' '${catalogJson}' ;;
  *) printf '000' ;;
esac
`, { mode: 0o755 })
  const env = { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}` }
  delete env.SIDECAR_STATE_DIR
  delete env.SIDECAR_PLUGIN_DIR
  return { home, env }
}

// Run a script via execFileSync (argument array — no shell interpolation).
function run(file, args, env, { input } = {}) {
  try {
    const stdout = execFileSync(file, args, { env, input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] })
    return { code: 0, stdout, stderr: '' }
  } catch (e) {
    return { code: e.status, stdout: e.stdout ?? '', stderr: e.stderr ?? '' }
  }
}

const locate = (env) =>
  run('bash', ['-c', 'source "$1"; echo "$SIDECAR_STATE_DIR"', 'bash', path.join(SCRIPTS, '_locate.sh')], env)
    .stdout.trim()

test('_locate: explicit SIDECAR_STATE_DIR env override wins', () => {
  const { env } = makeEnv()
  assert.equal(locate({ ...env, SIDECAR_STATE_DIR: '/explicit/override' }), '/explicit/override')
})

test('_locate: finds existing sidecar-state with .env.local; prefers it over legacy', () => {
  const { home, env } = makeEnv({ folders: ['AFolder', 'BFolder'] })
  fs.mkdirSync(path.join(home, 'mnt/BFolder/.sidecar'), { recursive: true })
  fs.writeFileSync(path.join(home, 'mnt/BFolder/.sidecar/.env.local'), 'x=1\n')
  fs.mkdirSync(path.join(home, 'mnt/AFolder/sidecar-state'), { recursive: true })
  fs.writeFileSync(path.join(home, 'mnt/AFolder/sidecar-state/.env.local'), 'x=1\n')
  assert.equal(locate(env), path.join(home, 'mnt/AFolder/sidecar-state'))
})

test('_locate: legacy .sidecar recognized when no sidecar-state exists', () => {
  const { home, env } = makeEnv()
  fs.mkdirSync(path.join(home, 'mnt/MyFolder/.sidecar'), { recursive: true })
  fs.writeFileSync(path.join(home, 'mnt/MyFolder/.sidecar/.env.local'), 'x=1\n')
  assert.equal(locate(env), path.join(home, 'mnt/MyFolder/.sidecar'))
})

test('_locate: first-run fallback skips outputs/uploads/dotdirs', () => {
  const { home, env } = makeEnv({ folders: ['outputs', 'uploads', '.hidden', 'RealFolder'] })
  assert.equal(locate(env), path.join(home, 'mnt/RealFolder/sidecar-state'))
})

test('_locate: hard default when nothing mounted', () => {
  const { home, env } = makeEnv({ folders: [] })
  assert.equal(locate(env), path.join(home, 'mnt/ClaudeCowork/sidecar-state'))
})

function seededState(home) {
  const state = path.join(home, 'mnt/MyFolder/sidecar-state')
  fs.mkdirSync(state, { recursive: true })
  fs.copyFileSync(path.join(REPO, 'skills/sidecar/.env.local.template'), path.join(state, '.env.local'))
  return state
}

test('set-key: accepts sk-or-* via stdin, updates file, never echoes the key', () => {
  const { home, env } = makeEnv()
  const state = seededState(home)
  const key = 'sk-or-v1-testkey1234'
  const r = run('bash', [path.join(SCRIPTS, 'set-key.sh')], { ...env, SIDECAR_STATE_DIR: state }, { input: key + '\n' })
  assert.equal(r.code, 0, r.stderr)
  assert.ok(!r.stdout.includes(key) && !r.stderr.includes(key), 'key must never be echoed')
  const envFile = fs.readFileSync(path.join(state, '.env.local'), 'utf8')
  assert.match(envFile, new RegExp(`^OPENROUTER_API_KEY="${key}"$`, 'm'))
})

test('set-key: rejects non sk-or keys with exit 3 and leaves file untouched', () => {
  const { home, env } = makeEnv()
  const state = seededState(home)
  const before = fs.readFileSync(path.join(state, '.env.local'), 'utf8')
  const r = run('bash', [path.join(SCRIPTS, 'set-key.sh'), 'sk-proj-wrong-vendor'], { ...env, SIDECAR_STATE_DIR: state })
  assert.equal(r.code, 3)
  assert.equal(fs.readFileSync(path.join(state, '.env.local'), 'utf8'), before)
})

test('set-model: rewrites both model lines, preserves everything else (stubbed catalog)', () => {
  const { home, env } = makeEnv()
  const state = seededState(home)
  const e = { ...env, SIDECAR_STATE_DIR: state }
  run('bash', [path.join(SCRIPTS, 'set-key.sh'), 'sk-or-v1-testkey1234'], e)
  const r = run('bash', [path.join(SCRIPTS, 'set-model.sh'), 'test/model-a', 'test/model-b'], e)
  assert.equal(r.code, 0, r.stderr)
  const f = fs.readFileSync(path.join(state, '.env.local'), 'utf8')
  assert.match(f, /^COMPLETION_MODEL="test\/model-a"$/m)
  assert.match(f, /^REASONING_MODEL="test\/model-b"$/m)
  assert.match(f, /^PORT=3000$/m)                       // untouched line preserved
  assert.match(f, /^ANTHROPIC_BASE_URL=/m)
})

test('set-model: unknown slug rejected by catalog check, file untouched', () => {
  const { home, env } = makeEnv()
  const state = seededState(home)
  const e = { ...env, SIDECAR_STATE_DIR: state }
  run('bash', [path.join(SCRIPTS, 'set-key.sh'), 'sk-or-v1-testkey1234'], e)
  const before = fs.readFileSync(path.join(state, '.env.local'), 'utf8')
  const r = run('bash', [path.join(SCRIPTS, 'set-model.sh'), 'not/in-catalog'], e)
  assert.equal(r.code, 2)
  assert.equal(fs.readFileSync(path.join(state, '.env.local'), 'utf8'), before)
})

test('setup: idempotent — second run exits 0 and preserves an edited .env.local', () => {
  const { home, env } = makeEnv()
  const state = path.join(home, 'mnt/MyFolder/sidecar-state')
  const e = { ...env, SIDECAR_STATE_DIR: state }
  const r1 = run('bash', [path.join(SCRIPTS, 'setup.sh')], e)
  assert.equal(r1.code, 0, r1.stderr)
  assert.ok(fs.existsSync(path.join(state, '.env.local')), 'seeded from template')
  run('bash', [path.join(SCRIPTS, 'set-key.sh'), 'sk-or-v1-keepme9999'], e)
  const r2 = run('bash', [path.join(SCRIPTS, 'setup.sh')], e)
  assert.equal(r2.code, 0, r2.stderr)
  assert.match(fs.readFileSync(path.join(state, '.env.local'), 'utf8'), /sk-or-v1-keepme9999/)
})
```

**Step 2: Run** — `node --test tests/integration/scripts.test.mjs`
Expected: all PASS. Likely first-run wrinkles (fix the TEST, not the script, unless the script is genuinely wrong):
- The curl stub's case patterns must match how `setup.sh` (`-o /dev/null -w "%{http_code}"`) vs `set-model.sh` (`.../models" -H ...`) invoke it — if a test misroutes, add `echo "ARGS: $*" >&2` to the stub temporarily.
- `setup.sh` requires the real `node` and the stub `claude` to be on PATH — both are (stub bin is *prepended*, system PATH retained).
- The `locate` helper passes the script path as `$1` with `bash -c '... "$1" ...' bash <path>` — positional, not interpolated.

**Step 3: Run the whole Tier 1 suite** — `bash tests/run-integration.sh` → PASS.

**Step 4: Commit** — `git add tests/integration/scripts.test.mjs && git commit -m "test: script smoke tests (_locate, set-key, set-model, setup idempotency)"`

---

### Task 11: Tier 2 live matrix

**Files:**
- Create: `tests/live/matrix.sh`

**Step 1: Write the script (complete code)**

```bash
#!/usr/bin/env bash
# matrix.sh — Tier 2 LIVE verification against real OpenRouter.
# Costs real money (pennies). Needs a valid key in .env.local (via _locate.sh)
# or $OPENROUTER_API_KEY. Run manually before tagging a release.
#
# For each model (one per provider-strictness family) it boots the real proxy
# and runs 4 probes: completion, tool round-trip (C1), mixed turn (C2),
# streaming SSE shape. Then one claude-CLI pong on the first model.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
SCRIPTS="$REPO/skills/sidecar/scripts"
BUNDLE="$REPO/skills/sidecar/proxy/bundle.cjs"

# Strictness matrix: lenient (Gemini) / strict (DeepSeek) / strict+Responses-path (OpenAI).
# Verify slugs with list-models.sh if a probe 404s.
MODELS=(
  "google/gemini-3-flash-preview"
  "deepseek/deepseek-v3.2"
  "openai/gpt-4o-mini"
)

# Key: env override, else .env.local via _locate.sh.
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPTS/_locate.sh"
  [ -f "$SIDECAR_STATE_DIR/.env.local" ] && { set -a; source "$SIDECAR_STATE_DIR/.env.local"; set +a; }
fi
if [ -z "${OPENROUTER_API_KEY:-}" ] || [ "${OPENROUTER_API_KEY:0:6}" != "sk-or-" ]; then
  echo "error: no valid OPENROUTER_API_KEY (env or .env.local)" >&2; exit 1
fi

PASS=0; FAIL=0; GRID=""
probe() { # $1=label $2=expect-grep(optional) $3=json-payload  (uses $PORT $MODEL)
  local resp
  resp=$(curl -sS --max-time 90 "http://127.0.0.1:$PORT/v1/messages" \
    -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d "$3")
  if echo "$resp" | grep -q '"error"'; then
    FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  $1 — ${resp:0:160}\n"; return 1
  fi
  if [ -n "$2" ] && ! echo "$resp" | grep -q "$2"; then
    FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  $1 — missing '$2': ${resp:0:160}\n"; return 1
  fi
  PASS=$((PASS+1)); GRID="$GRID  PASS  $MODEL  $1\n"
}

boot_proxy() { # uses $MODEL; sets $PORT $PROXY_PID; returns 1 on boot failure
  PORT=$(( ( RANDOM % 2000 ) + 33000 ))
  OPENROUTER_API_KEY="$OPENROUTER_API_KEY" COMPLETION_MODEL="$MODEL" REASONING_MODEL="$MODEL" \
    PORT="$PORT" node "$BUNDLE" >"/tmp/sidecar-matrix-$PORT.log" 2>&1 &
  PROXY_PID=$!
  for i in $(seq 1 40); do (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0; sleep 0.25; done
  return 1
}

for MODEL in "${MODELS[@]}"; do
  echo "=== $MODEL ==="
  if ! boot_proxy; then
    FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  proxy-boot\n"; kill "$PROXY_PID" 2>/dev/null; continue
  fi

  # max_tokens=300: reasoning models burn ~100 tokens of CoT before visible text
  # (same lesson as test.sh's 200-token floor; 300 adds margin for newer models).
  probe "completion " '"type":"text"' \
    '{"model":"x","max_tokens":300,"messages":[{"role":"user","content":"say ok"}]}'

  probe "tool-rtrip " '' \
    '{"model":"x","max_tokens":300,"messages":[
      {"role":"user","content":"What is 2+2?"},
      {"role":"assistant","content":[{"type":"tool_use","id":"toolu_m1","name":"calc","input":{"expr":"2+2"}}]},
      {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_m1","content":"4"}]}]}'

  probe "mixed-turn " '' \
    '{"model":"x","max_tokens":300,"messages":[
      {"role":"user","content":"What files are in /tmp?"},
      {"role":"assistant","content":[{"type":"text","text":"Checking."},{"type":"tool_use","id":"toolu_m2","name":"bash","input":{"command":"ls /tmp"}}]},
      {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_m2","content":"file1.txt"},{"type":"text","text":"<system-reminder>be brief</system-reminder>"}]}]}'

  STREAM_RESP=$(curl -sS --max-time 90 "http://127.0.0.1:$PORT/v1/messages" \
    -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
    -d '{"model":"x","max_tokens":300,"stream":true,"messages":[{"role":"user","content":"say ok"}]}')
  if echo "$STREAM_RESP" | grep -q "event: message_start" && echo "$STREAM_RESP" | grep -q "event: message_stop"; then
    PASS=$((PASS+1)); GRID="$GRID  PASS  $MODEL  stream-sse \n"
  else
    FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  stream-sse — ${STREAM_RESP:0:160}\n"
  fi

  kill "$PROXY_PID" 2>/dev/null; wait "$PROXY_PID" 2>/dev/null
done

# One claude-CLI pong on the first model (full client-compat check).
if command -v claude >/dev/null 2>&1; then
  MODEL="${MODELS[0]}"
  if boot_proxy; then
    CLI_OUT=$(ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY="proxy-ignores-this" ANTHROPIC_AUTH_TOKEN="" \
      timeout 60 claude -p "Reply with one short sentence containing the word 'pong'." </dev/null 2>&1)
    if echo "$CLI_OUT" | grep -qi pong; then PASS=$((PASS+1)); GRID="$GRID  PASS  $MODEL  claude-cli \n"
    else FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  claude-cli — ${CLI_OUT:0:160}\n"; fi
    kill "$PROXY_PID" 2>/dev/null
  else
    FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  proxy-boot(cli)\n"; kill "$PROXY_PID" 2>/dev/null
  fi
else
  GRID="$GRID  SKIP  claude CLI not installed\n"
fi

echo; echo "=== live matrix results ==="; printf "%b" "$GRID"
echo; echo "PASS: $PASS  FAIL: $FAIL"
exit "$FAIL"
```

**Step 2: Syntax check (free)** — `bash -n tests/live/matrix.sh` → no output, exit 0.

**Step 3: Live run (costs pennies — requires a configured key)**

Run: `bash tests/live/matrix.sh`
Expected: per-model PASS lines for all 4 probes × 3 models + claude-cli, exit 0.
- A 404 "No allowed providers" on DeepSeek means the OpenRouter account needs providers enabled (see README "Provider allowlists") — an account issue, not a code failure; note it and continue.
- If a slug 404s as unknown, find the current one with `bash skills/sidecar/scripts/list-models.sh <vendor>` and update `MODELS`.

**Step 4: Commit** — `git add tests/live/matrix.sh && git commit -m "test: live 3-provider OpenRouter matrix (lenient + strict providers)"`

---

### Task 12: Document the suite + final verification

**Files:**
- Modify: `README.md` (the "What's in here" tree + Usage section)

**Step 1: Add to README**

In the repo tree block, after the `skills/sidecar/` entries, add:

```
└── tests/                     # dev-only, never shipped in the .plugin
    ├── integration/           # bash tests/run-integration.sh — no network, no key
    └── live/matrix.sh         # real-OpenRouter 3-provider matrix (run before release)
```

In the "From a repo checkout" usage block, add:

```bash
bash tests/run-integration.sh                            # Tier 1: mock-based, free
bash tests/live/matrix.sh                                # Tier 2: live, needs key
```

**Step 2: Full verification**

Run: `bash tests/run-integration.sh`
Expected: all tests PASS, exit 0.

Run: `bash build.sh && unzip -Z1 ../sidecar.plugin | grep -cE '^(tests|docs)/'; true`
Expected: `0`.

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document two-tier test suite in README"
```

---

## Execution notes

- Tasks 2→3 are sequential (harness depends on fake). Tasks 4–7 and 10 are independent of each other once 3 lands. Task 8 must precede 9 (same file). Task 11 is independent. Task 12 last.
- Every test must clean up its child processes (`proxy.stop()` in `finally`/`after`) — a leaked proxy process makes later tests flaky.
- If an assertion fails against `bundle.cjs` but passes against the source (`SIDECAR_TEST_ENTRY=skills/sidecar/proxy/anthropic-proxy-patched.mjs bash tests/run-integration.sh`), the bundle is stale: `bash build.sh`.
- Do not loosen an assertion to make a test pass without understanding why the proxy behaves differently — these tests exist to lock the documented patch behaviors.
- Never use `exec`/`execSync` with interpolated strings in test code — `execFileSync` with argument arrays only (repo hook enforces this).
