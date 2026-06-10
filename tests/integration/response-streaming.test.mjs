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

test('P3: incremental-fragment tool-call arguments (real OpenAI style) reassemble correctly', async () => {
  fake.respondWith(sseResponder([
    sseDelta({ tool_calls: [{ index: 0, id: 'call_p3', function: { name: 'calc', arguments: '{"ex' } }] }),
    sseDelta({ tool_calls: [{ index: 0, function: { arguments: 'pr":"2+2"' } }] }),
    sseDelta({ tool_calls: [{ index: 0, function: { arguments: '}' } }] }),
    DONE,
  ]))
  const r = await postMessages(proxy.url, anthropicPayload({ stream: true }))
  const events = parseSSE(r.text)
  const parts = events.filter(e => e.event === 'content_block_delta').map(e => e.data.delta.partial_json)
  assert.equal(parts.join(''), '{"expr":"2+2"}')
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
