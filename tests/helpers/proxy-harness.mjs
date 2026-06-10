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
  // Fail fast with the child's own output if it dies before listening —
  // otherwise a bad entry/stale bundle burns the full poll timeout opaquely.
  const exited = new Promise((_, reject) => {
    proc.once('exit', code =>
      reject(new Error(`proxy exited (code ${code}) before listening:\n${logs}`)))
  })
  await Promise.race([waitForListen(port), exited])
  exited.catch(() => {})  // defuse: the same rejection fires later on stop()
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
