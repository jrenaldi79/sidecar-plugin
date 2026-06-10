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
