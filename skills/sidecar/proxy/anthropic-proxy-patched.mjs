// anthropic-proxy-patched.mjs — vendored fork of anthropic-proxy v1.3.x with
// streaming-stability patches applied. See PROXY-PATCHES.md for the diff
// rationale. Regenerate with: cp node_modules/anthropic-proxy/index.js
// anthropic-proxy-patched.mjs && re-apply the 7 patches.
//
// Patches applied:
//   B1 — guard reply.code(500) with !reply.raw.headersSent
//   B2 — try/catch around JSON.parse of SSE chunks (line ~323)
//   B3 — handle null openaiMessage.content in non-streaming path (lines ~202, ~224)
//   B4 — streaming opt-in via $SIDECAR_STREAMING (default off until B1-B3 prove robust)
//   P1 — try/catch around JSON.parse of tool_call arguments (line ~209)
//   P2 — AbortSignal.timeout(120000) on the upstream fetch
//
// Bugs B1-B4 reported by John Renaldi 2026-04-29; P1 P2 added preventively.

import Fastify from 'fastify'
import { TextDecoder } from 'util'

const baseUrl = process.env.ANTHROPIC_PROXY_BASE_URL || 'https://openrouter.ai/api'
const requiresApiKey = !process.env.ANTHROPIC_PROXY_BASE_URL
const key = requiresApiKey ? process.env.OPENROUTER_API_KEY : null
const model = 'google/gemini-2.0-pro-exp-02-05:free'
const models = {
  reasoning: process.env.REASONING_MODEL || model,
  completion: process.env.COMPLETION_MODEL || model,
}

const fastify = Fastify({
  logger: true
})
function debug(...args) {
  if (!process.env.DEBUG) return
  console.log(...args)
}

// Helper function to send SSE events and flush immediately.
const sendSSE = (reply, event, data) => {
  const sseMessage = `event: ${event}\n` +
                     `data: ${JSON.stringify(data)}\n\n`
  reply.raw.write(sseMessage)
  // Flush if the flush method is available.
  if (typeof reply.raw.flush === 'function') {
    reply.raw.flush()
  }
}

function mapStopReason(finishReason) {
  switch (finishReason) {
    case 'tool_calls': return 'tool_use'
    case 'stop': return 'end_turn'
    case 'length': return 'max_tokens'
    default: return 'end_turn'
  }
}

fastify.post('/v1/messages', async (request, reply) => {
  try {
    const payload = request.body

    // Helper to normalize a message's content.
    // If content is a string, return it directly.
    // If it's an array (of objects with text property), join them.
    const normalizeContent = (content) => {
      if (typeof content === 'string') return content
      if (Array.isArray(content)) {
        return content.map(item => item.text).join(' ')
      }
      return null
    }

    // Build messages array for the OpenAI payload.
    // Start with system messages if provided.
    const messages = []
    if (payload.system && Array.isArray(payload.system)) {
      payload.system.forEach(sysMsg => {
        const normalized = normalizeContent(sysMsg.text || sysMsg.content)
        if (normalized) {
          messages.push({
            role: 'system',
            content: normalized
          })
        }
      })
    }
    // Then add user (or other) messages.
    //
    // PATCH C1+C2 — Anthropic→OpenAI message translation correctness.
    //
    //   C1 (tool_calls shape): the original mapping wrapped each call in
    //   { function: { type, id, function: { name, parameters } } }. The
    //   correct OpenAI shape is { id, type:'function', function: { name,
    //   arguments: <JSON-string> } } — id/type live at the top, single
    //   `function` layer, and arguments must be a JSON-encoded *string*,
    //   not the original object. Strict deserializers (DeepSeek, OpenAI
    //   via Responses-API) rejected the malformed shape; Gemini's adapter
    //   masked it by accepting either form.
    //
    //   C2 (message ordering): when a user message contains both text and
    //   tool_result blocks (Claude CLI does this — system-reminders ride
    //   along on the same turn that delivers tool results), tool_result
    //   messages MUST be emitted before any user-text message so they're
    //   adjacent to the prior assistant tool_calls. The OpenAI schema
    //   requires this adjacency. The pre-patch code emitted user-text
    //   first.
    //
    //   Secondary: tool_result.content can be a string OR an array of
    //   content blocks. OpenAI requires a string — so we stringify.
    if (payload.messages && Array.isArray(payload.messages)) {
      const stringifyToolResult = (tr) => {
        const c = tr.content
        if (typeof c === 'string') return c
        if (Array.isArray(c)) return c.map(b => (b && b.text) || '').join('')
        return tr.text || ''
      }

      payload.messages.forEach(msg => {
        const items = Array.isArray(msg.content) ? msg.content : []
        const toolUses = items.filter(it => it.type === 'tool_use')
        const toolResults = items.filter(it => it.type === 'tool_result')
        const textBlocks = items.filter(it => it.type === 'text')
        const isUser = msg.role !== 'assistant'

        if (isUser) {
          // Tool results FIRST — they must be adjacent to the prior assistant tool_calls.
          toolResults.forEach(tr => {
            messages.push({
              role: 'tool',
              content: stringifyToolResult(tr),
              tool_call_id: tr.tool_use_id,
            })
          })
          // Then any user text as a separate user message.
          let userText = null
          if (typeof msg.content === 'string') userText = msg.content
          else if (textBlocks.length > 0) userText = textBlocks.map(b => b.text || '').join('')
          if (userText) messages.push({ role: 'user', content: userText })
        } else {
          // Assistant: combine text + tool_calls into a single message.
          const newMsg = { role: 'assistant' }
          let txt = null
          if (typeof msg.content === 'string') txt = msg.content
          else if (textBlocks.length > 0) txt = textBlocks.map(b => b.text || '').join('')
          if (txt) newMsg.content = txt
          if (toolUses.length > 0) {
            newMsg.tool_calls = toolUses.map(tu => ({
              id: tu.id,
              type: 'function',
              function: {
                name: tu.name,
                arguments: JSON.stringify(tu.input || {}),
              },
            }))
          }
          if (newMsg.content || newMsg.tool_calls) messages.push(newMsg)
        }
      })
    }

    // Prepare the OpenAI payload.
    // Helper function to recursively traverse JSON schema and remove format: 'uri'
    const removeUriFormat = (schema) => {
      if (!schema || typeof schema !== 'object') return schema;

      // If this is a string type with uri format, remove the format
      if (schema.type === 'string' && schema.format === 'uri') {
        const { format, ...rest } = schema;
        return rest;
      }

      // Handle array of schemas (like in anyOf, allOf, oneOf)
      if (Array.isArray(schema)) {
        return schema.map(item => removeUriFormat(item));
      }

      // Recursively process all properties
      const result = {};
      for (const key in schema) {
      if (key === 'properties' && typeof schema[key] === 'object') {
        result[key] = {};
        for (const propKey in schema[key]) {
          result[key][propKey] = removeUriFormat(schema[key][propKey]);
        }
      } else if (key === 'items' && typeof schema[key] === 'object') {
        result[key] = removeUriFormat(schema[key]);
      } else if (key === 'additionalProperties' && typeof schema[key] === 'object') {
        result[key] = removeUriFormat(schema[key]);
      } else if (['anyOf', 'allOf', 'oneOf'].includes(key) && Array.isArray(schema[key])) {
        result[key] = schema[key].map(item => removeUriFormat(item));
      } else {
        result[key] = removeUriFormat(schema[key]);
      }
      }
      return result;
    };

    const tools = (payload.tools || []).filter(tool => !['BatchTool'].includes(tool.name)).map(tool => ({
      type: 'function',
      function: {
        name: tool.name,
        description: tool.description,
        parameters: removeUriFormat(tool.input_schema),
      },
    }))
    const openaiPayload = {
      model: payload.thinking ? models.reasoning : models.completion,
      messages,
      max_tokens: payload.max_tokens,
      temperature: payload.temperature !== undefined ? payload.temperature : 1,
      // PATCH B4 — Streaming is opt-in. Defaults to false because Gemini's
      // OpenAI-compat SSE format triggers parse errors that crash the stream
      // path (see B1, B2 below). Set SIDECAR_STREAMING=true to re-enable
      // streaming once those fixes are battle-tested.
      stream: process.env.SIDECAR_STREAMING === 'true' ? payload.stream === true : false,
    }
    if (tools.length > 0) openaiPayload.tools = tools
    debug('OpenAI payload:', openaiPayload)

    const headers = {
      'Content-Type': 'application/json'
    }
    
    if (requiresApiKey) {
      headers['Authorization'] = `Bearer ${key}`
    }
    
    // PATCH P2 — Add a 120s upstream timeout. Without this, a hung Gemini
    // request could leave the proxy waiting forever (and the client
    // observing it as "no response").
    const openaiResponse = await fetch(`${baseUrl}/v1/chat/completions`, {
      method: 'POST',
      headers,
      body: JSON.stringify(openaiPayload),
      signal: AbortSignal.timeout(120000)
    });

    if (!openaiResponse.ok) {
      const errorDetails = await openaiResponse.text()
      reply.code(openaiResponse.status)
      return { error: errorDetails }
    }

    // If stream is not enabled, process the complete response.
    if (!openaiPayload.stream) {
      const data = await openaiResponse.json()
      debug('OpenAI response:', data)
      if (data.error) {
        throw new Error(data.error.message)
      }


      const choice = data.choices[0]
      const openaiMessage = choice.message

      // Map finish_reason to anthropic stop_reason.
      const stopReason = mapStopReason(choice.finish_reason)
      const toolCalls = openaiMessage.tool_calls || []

      // Create a message id; if available, replace prefix, otherwise generate one.
      const messageId = data.id
        ? data.id.replace('chatcmpl', 'msg')
        : 'msg_' + Math.random().toString(36).substr(2, 24)

      // PATCH P1 — guard JSON.parse of tool-call arguments. Gemini occasionally
      // emits malformed JSON in tool_calls.function.arguments; treat as empty.
      const safeJsonParse = (s) => {
        try { return JSON.parse(s) } catch (_) { return {} }
      }

      const anthropicResponse = {
        content: [
          // PATCH B3 — only emit a text block if content is non-null. Pure
          // tool-call turns from Gemini have content === null, which crashes
          // the Claude CLI when it tries to call .text.trim() on it.
          ...(openaiMessage.content != null ? [{
            text: openaiMessage.content,
            type: 'text'
          }] : []),
          ...toolCalls.map(toolCall => ({
            type: 'tool_use',
            id: toolCall.id,
            name: toolCall.function.name,
            input: safeJsonParse(toolCall.function.arguments),
          })),
        ],
        id: messageId,
        model: openaiPayload.model,
        role: openaiMessage.role,
        stop_reason: stopReason,
        stop_sequence: null,
        type: 'message',
        usage: {
          input_tokens: data.usage
            ? data.usage.prompt_tokens
            : messages.reduce((acc, msg) => acc + (msg.content || '').split(' ').length, 0),
          output_tokens: data.usage
            ? data.usage.completion_tokens
            // PATCH B3 — guard split when content is null.
            : (openaiMessage.content || '').split(' ').length,
        }
      }

      return anthropicResponse
    }


    let isSucceeded = false
    function sendSuccessMessage() {
      if (isSucceeded) return
      isSucceeded = true

      // Streaming response using Server-Sent Events.
      reply.raw.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive'
      })

      // Create a unique message id.
      const messageId = 'msg_' + Math.random().toString(36).substr(2, 24)

      // Send initial SSE event for message start.
      sendSSE(reply, 'message_start', {
        type: 'message_start',
        message: {
          id: messageId,
          type: 'message',
          role: 'assistant',
          model: openaiPayload.model,
          content: [],
          stop_reason: null,
          stop_sequence: null,
          usage: { input_tokens: 0, output_tokens: 0 },
        }
      })

      // Send initial ping.
      sendSSE(reply, 'ping', { type: 'ping' })
    }

    // Prepare for reading streamed data.
    let accumulatedContent = ''
    let accumulatedReasoning = ''
    let usage = null
    let textBlockStarted = false
    let encounteredToolCall = false
    const toolCallAccumulators = {}  // key: tool call index, value: accumulated arguments string
    const decoder = new TextDecoder('utf-8')
    const reader = openaiResponse.body.getReader()
    let done = false

    while (!done) {
      const { value, done: doneReading } = await reader.read()
      done = doneReading
      if (value) {
        const chunk = decoder.decode(value)
        debug('OpenAI response chunk:', chunk)
        // OpenAI streaming responses are typically sent as lines prefixed with "data: "
        const lines = chunk.split('\n')


        for (const line of lines) {
          const trimmed = line.trim()
          if (trimmed === '' || !trimmed.startsWith('data:')) continue
          const dataStr = trimmed.replace(/^data:\s*/, '')
          if (dataStr === '[DONE]') {
            // Finalize the stream with stop events.
            if (encounteredToolCall) {
              for (const idx in toolCallAccumulators) {
                sendSSE(reply, 'content_block_stop', {
                  type: 'content_block_stop',
                  index: parseInt(idx, 10)
                })
              }
            } else if (textBlockStarted) {
              sendSSE(reply, 'content_block_stop', {
                type: 'content_block_stop',
                index: 0
              })
            }
            sendSSE(reply, 'message_delta', {
              type: 'message_delta',
              delta: {
                stop_reason: encounteredToolCall ? 'tool_use' : 'end_turn',
                stop_sequence: null
              },
              usage: usage
                ? { output_tokens: usage.completion_tokens }
                : { output_tokens: accumulatedContent.split(' ').length + accumulatedReasoning.split(' ').length }
            })
            sendSSE(reply, 'message_stop', {
              type: 'message_stop'
            })
            reply.raw.end()
            return
          }

          // PATCH B2 — Gemini's SSE stream occasionally emits non-JSON `data:`
          // lines (heartbeats, partial chunks, leading whitespace). Without
          // this guard, JSON.parse throws SyntaxError, the catch block tries
          // to send a 500 response after headers are already sent, and the
          // proxy crashes (see B1).
          let parsed
          try {
            parsed = JSON.parse(dataStr)
          } catch (_) {
            continue
          }
          if (parsed.error) {
            throw new Error(parsed.error.message)
          }
          sendSuccessMessage()
          // Capture usage if available.
          if (parsed.usage) {
            usage = parsed.usage
          }
          const delta = parsed.choices[0].delta
          if (delta && delta.tool_calls) {
            for (const toolCall of delta.tool_calls) {
              encounteredToolCall = true
              const idx = toolCall.index
              if (toolCallAccumulators[idx] === undefined) {
                toolCallAccumulators[idx] = ""
                sendSSE(reply, 'content_block_start', {
                  type: 'content_block_start',
                  index: idx,
                  content_block: {
                    type: 'tool_use',
                    id: toolCall.id,
                    name: toolCall.function.name,
                    input: {}
                  }
                })
              }
              const newArgs = toolCall.function.arguments || ""
              const oldArgs = toolCallAccumulators[idx]
              if (newArgs.length > oldArgs.length) {
                const deltaText = newArgs.substring(oldArgs.length)
                sendSSE(reply, 'content_block_delta', {
                  type: 'content_block_delta',
                  index: idx,
                  delta: {
                    type: 'input_json_delta',
                    partial_json: deltaText
                  }
                })
                toolCallAccumulators[idx] = newArgs
              }
            }
          } else if (delta && delta.content) {
            if (!textBlockStarted) {
              textBlockStarted = true
              sendSSE(reply, 'content_block_start', {
                type: 'content_block_start',
                index: 0,
                content_block: {
                  type: 'text',
                  text: ''
                }
              })
            }
            accumulatedContent += delta.content
            sendSSE(reply, 'content_block_delta', {
              type: 'content_block_delta',
              index: 0,
              delta: {
                type: 'text_delta',
                text: delta.content
              }
            })
          } else if (delta && delta.reasoning) {
            if (!textBlockStarted) {
              textBlockStarted = true
              sendSSE(reply, 'content_block_start', {
                type: 'content_block_start',
                index: 0,
                content_block: {
                  type: 'text',
                  text: ''
                }
              })
            }
            accumulatedReasoning += delta.reasoning
            sendSSE(reply, 'content_block_delta', {
              type: 'content_block_delta',
              index: 0,
              delta: {
                type: 'thinking_delta',
                thinking: delta.reasoning
              }
            })
          }
        }
      }
    }

    reply.raw.end()
  } catch (err) {
    console.error(err)
    // PATCH B1 — Don't try to set a status code on a response that's already
    // streaming. After reply.raw.writeHead() runs (which sendSuccessMessage
    // does for streaming requests), reply.code() throws ERR_HTTP_HEADERS_SENT
    // and crashes the entire Node process. End the stream cleanly instead.
    if (!reply.raw.headersSent) {
      reply.code(500)
      return { error: err.message }
    }
    try { reply.raw.end() } catch (_) {}
  }
})

const start = async () => {
  try {
    await fastify.listen({ port: process.env.PORT || 3000 })
  } catch (err) {
    process.exit(1)
  }
}

start()
