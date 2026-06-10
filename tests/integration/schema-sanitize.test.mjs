// schema-sanitize.test.mjs — P4 regression locks. Google's
// GenerateContentRequest validator rejects tool schemas whose `required`
// array names properties that aren't defined in `properties` (error:
// "parameters.required[N]: property is not defined"). OpenAI and DeepSeek
// tolerate the same schemas, which masked the bug until a live Gemini run
// (2026-06-09) failed mid-conversation. Real Claude CLI / MCP tool schemas
// do ship such entries, so the proxy must sanitize.
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

test('P4: required entries with no matching property are dropped', async () => {
  await postMessages(proxy.url, anthropicPayload({
    tools: [{
      name: 'sloppy',
      description: 'tool with ghost required entries',
      input_schema: {
        type: 'object',
        properties: { a: { type: 'string' }, b: { type: 'number' } },
        required: ['a', 'ghost1', 'b', 'ghost2'],
      },
    }],
  }))
  const params = fake.lastRequest().body.tools[0].function.parameters
  assert.deepEqual(params.required, ['a', 'b'])
})

test('P4: sanitization recurses into nested schemas (items)', async () => {
  await postMessages(proxy.url, anthropicPayload({
    tools: [{
      name: 'nested',
      description: 'ghost required inside array items',
      input_schema: {
        type: 'object',
        properties: {
          list: {
            type: 'array',
            items: {
              type: 'object',
              properties: { x: { type: 'string' } },
              required: ['x', 'ghost'],
            },
          },
        },
        required: ['list'],
      },
    }],
  }))
  const params = fake.lastRequest().body.tools[0].function.parameters
  assert.deepEqual(params.properties.list.items.required, ['x'])
  assert.deepEqual(params.required, ['list'])
})

test('P4: required with no surviving entries is removed entirely', async () => {
  await postMessages(proxy.url, anthropicPayload({
    tools: [{
      name: 'allghosts',
      description: 'required names nothing that exists',
      input_schema: { type: 'object', properties: {}, required: ['ghost'] },
    }],
  }))
  const params = fake.lastRequest().body.tools[0].function.parameters
  assert.equal('required' in params, false)
})

test('P5: enum on a non-string type is dropped (Gemini-incompatible)', async () => {
  // Live finding (2026-06-09, Fireflies MCP tool): {type:'number', enum:[7,14,30]}
  // makes Google's converter discard the whole surrounding properties map,
  // which then 400s with "required[N]: property is not defined" for SIBLING
  // properties. Bisected construct-by-construct against live Gemini Flash.
  await postMessages(proxy.url, anthropicPayload({
    tools: [{
      name: 'share',
      description: 'numeric enum trigger',
      input_schema: {
        type: 'object',
        properties: {
          meetingId: { type: 'string' },
          expiryDays: { type: 'number', enum: [7, 14, 30], description: 'one of 7, 14, 30' },
        },
        required: ['meetingId'],
      },
    }],
  }))
  const params = fake.lastRequest().body.tools[0].function.parameters
  assert.equal('enum' in params.properties.expiryDays, false)
  assert.equal(params.properties.expiryDays.type, 'number')
  assert.deepEqual(params.required, ['meetingId'])
})

test('P5: string enums are preserved', async () => {
  await postMessages(proxy.url, anthropicPayload({
    tools: [{
      name: 'pick',
      description: 'string enum is Gemini-supported',
      input_schema: {
        type: 'object',
        properties: { mode: { type: 'string', enum: ['fast', 'slow'] } },
        required: ['mode'],
      },
    }],
  }))
  const params = fake.lastRequest().body.tools[0].function.parameters
  assert.deepEqual(params.properties.mode.enum, ['fast', 'slow'])
})

test('P4: valid required arrays pass through untouched', async () => {
  await postMessages(proxy.url, anthropicPayload({
    tools: [{
      name: 'clean',
      description: 'nothing to sanitize',
      input_schema: {
        type: 'object',
        properties: { a: { type: 'string' } },
        required: ['a'],
      },
    }],
  }))
  const params = fake.lastRequest().body.tools[0].function.parameters
  assert.deepEqual(params.required, ['a'])
})
