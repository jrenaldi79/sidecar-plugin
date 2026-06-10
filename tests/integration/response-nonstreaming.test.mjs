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
