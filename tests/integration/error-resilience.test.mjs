// error-resilience.test.mjs — Tier 1 tests for proxy error handling:
// upstream timeout (P2), garbage SSE lines (B2), mid-stream errors (B1),
// HTTP status passthrough, and multi-request process survival.
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
