// request-translation.test.mjs — regression locks for Anthropic -> OpenAI
// request translation (C1, C2, tools mapping, model routing, B4).
// Asserts on fake.lastRequest().body — the OpenAI payload the proxy sent.
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

test('format:uri stripped inside allOf, oneOf, and array items', async () => {
  await postMessages(proxy.url, anthropicPayload({
    tools: [
      { name: 'deep', description: 'nested schemas', input_schema: {
          type: 'object',
          properties: {
            a: { allOf: [{ type: 'string', format: 'uri' }] },
            o: { oneOf: [{ type: 'string', format: 'uri' }, { type: 'number' }] },
            list: { type: 'array', items: { type: 'string', format: 'uri' } },
          } } },
    ],
  }))
  const params = fake.lastRequest().body.tools[0].function.parameters
  assert.deepEqual(params.properties.a.allOf[0], { type: 'string' })
  assert.deepEqual(params.properties.o.oneOf[0], { type: 'string' })
  assert.deepEqual(params.properties.list.items, { type: 'string' })
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

test('B4: SIDECAR_STREAMING=false forces stream:false even when client asks to stream', async () => {
  const fake2 = await startFakeOpenRouter()
  const proxy2 = await startProxy({ upstreamUrl: fake2.url, env: { SIDECAR_STREAMING: 'false' } })
  try {
    await postMessages(proxy2.url, anthropicPayload({ stream: true }))
    assert.equal(fake2.lastRequest().body.stream, false)
  } finally { proxy2.stop(); await fake2.close() }
})
