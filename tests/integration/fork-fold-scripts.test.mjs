// fork-fold-scripts.test.mjs — integration locks for the 0.2.0 Fork & Fold
// CLI features: per-call model override, dynamic ports, sessions/--continue,
// fold contract, read-only tool defaults, retry-on-proxy-death, compare
// fan-out, and the defaults.env alias map. Uses the fake `claude` shim from
// cli-harness.mjs — no network, no key, no real CLI.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import net from 'node:net'
import path from 'node:path'
import os from 'node:os'
import { startFakeOpenRouter } from '../helpers/fake-openrouter.mjs'
import {
  makeCliEnv, runScript, runtimeEval, spawnStartSh, freePort, hasLsof,
} from '../helpers/cli-harness.mjs'

// ---------- _runtime.sh helpers ----------

test('resolve_model: vendor word resolves via defaults.env', async () => {
  const env = makeCliEnv()
  const r = await runtimeEval(env, 'resolve_model gemini')
  assert.equal(r.code, 0)
  assert.equal(r.stdout.trim(), 'fake/gemini-test')
})

test('resolve_model: full slug passes through untouched', async () => {
  const env = makeCliEnv()
  const r = await runtimeEval(env, 'resolve_model some-vendor/some-model:variant')
  assert.equal(r.code, 0)
  assert.equal(r.stdout.trim(), 'some-vendor/some-model:variant')
})

test('resolve_model: unknown vendor exits 2 with refresh-defaults hint', async () => {
  const env = makeCliEnv()
  const r = await runtimeEval(env, 'resolve_model nosuchvendor')
  assert.equal(r.code, 2)
  assert.match(r.stderr, /no model alias for 'nosuchvendor'/)
  assert.match(r.stderr, /refresh-defaults\.sh/)
})

test('pick_port: skips an occupied candidate', async () => {
  const env = makeCliEnv()
  const srv = net.createServer()
  const occupied = await new Promise(res => srv.listen(0, '127.0.0.1', () => res(srv.address().port)))
  try {
    // pick_port offsets by the calling shell's PID — compute the base inside
    // bash so base + offset lands exactly on the occupied port.
    const r = await runtimeEval(env, `base=$(( ${occupied} - ($$ % 500) )); pick_port "$base"`)
    assert.equal(r.code, 0)
    assert.equal(Number(r.stdout.trim()), occupied + 1)
  } finally {
    srv.close()
  }
})

// ---------- start.sh override channel ----------

test('start.sh: SIDECAR_PORT/COMPLETION_OVERRIDE win over .env.local', async () => {
  const env = makeCliEnv()
  const fake = await startFakeOpenRouter()
  const port = await freePort()
  const proxy = await spawnStartSh(env, {
    SIDECAR_PORT_OVERRIDE: String(port),
    SIDECAR_COMPLETION_OVERRIDE: 'fake/override-model',
    ANTHROPIC_PROXY_BASE_URL: fake.url,
  }, port)
  try {
    await fetch(`http://127.0.0.1:${port}/v1/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'client-junk', max_tokens: 50,
                             messages: [{ role: 'user', content: 'hi' }] }),
    })
    // .env.local says PORT=3300 + fake/default-model; the overrides must win.
    assert.equal(fake.lastRequest().body.model, 'fake/override-model')
  } finally {
    proxy.stop()
    await fake.close()
  }
})

// ---------- ask.sh ----------

test('ask.sh: routing header, canned result, read-only flags by default', async () => {
  const env = makeCliEnv()
  const r = await runScript(env, 'ask.sh', ['--model', 'gemini', 'say ok'])
  assert.equal(r.code, 0, r.stderr)
  const lines = r.stdout.split('\n')
  assert.equal(lines[0], '[sidecar: fake/gemini-test]')
  assert.match(r.stdout, /fake answer via port \d+/)

  const argv = env.read(env.recordings('argv')[0])
  assert.match(argv, /--output-format\njson\n/)
  assert.match(argv, /--allowedTools\nRead,Grep,Glob\n/)
  assert.match(argv, /--disallowedTools\nBash,Edit,Write,NotebookEdit,WebFetch,WebSearch\n/)
  assert.equal(env.read(env.recordings('stdin')[0]), 'say ok')
})

test('ask.sh: --full-tools drops the restriction flags', async () => {
  const env = makeCliEnv()
  const r = await runScript(env, 'ask.sh', ['--model', 'gemini', '--full-tools', 'say ok'])
  assert.equal(r.code, 0, r.stderr)
  const argv = env.read(env.recordings('argv')[0])
  assert.doesNotMatch(argv, /--allowedTools/)
  assert.doesNotMatch(argv, /--disallowedTools/)
})

test('ask.sh: --fold appends the fold contract to the system prompt', async () => {
  const env = makeCliEnv()
  const r = await runScript(env, 'ask.sh', ['--model', 'gemini', '--fold', 'say ok'])
  assert.equal(r.code, 0, r.stderr)
  const argv = env.read(env.recordings('argv')[0])
  assert.match(argv, /--append-system-prompt/)
  assert.match(argv, /--- FOLD ---/)
})

test('ask.sh: --add-dir paths are forwarded to the CLI', async () => {
  const env = makeCliEnv()
  const extraA = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-extra-'))
  const extraB = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-extra-'))
  const r = await runScript(env, 'ask.sh',
    ['--model', 'gemini', '--add-dir', extraA, '--add-dir', extraB, 'say ok'])
  assert.equal(r.code, 0, r.stderr)
  const argv = env.read(env.recordings('argv')[0])
  assert.match(argv, new RegExp(`--add-dir\\n${extraA}\\n`))
  assert.match(argv, new RegExp(`--add-dir\\n${extraB}\\n`))
})

test('ask.sh: records the session; --continue resumes it with the stored slug', async () => {
  const env = makeCliEnv()
  const first = await runScript(env, 'ask.sh', ['--model', 'gemini', 'first question'])
  assert.equal(first.code, 0, first.stderr)
  const session = env.read(env.sessionsFile).trim().split('\n').pop().split('\t')
  assert.equal(session[1], 'sess-fake-1')
  assert.equal(session[2], 'fake/gemini-test')

  const second = await runScript(env, 'ask.sh', ['--continue', 'follow-up'])
  assert.equal(second.code, 0, second.stderr)
  // Stored slug wins over .env.local's fake/default-model.
  assert.equal(second.stdout.split('\n')[0], '[sidecar: fake/gemini-test]')
  const argv = env.read(env.recordings('argv').pop())
  assert.match(argv, /--resume\nsess-fake-1\n/)
})

test('ask.sh: appends a history.log line with token usage', async () => {
  const env = makeCliEnv()
  await runScript(env, 'ask.sh', ['--model', 'gpt', 'say ok'])
  const line = env.read(env.historyFile).trim().split('\n').pop()
  const f = line.split('\t')
  assert.match(f[0], /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
  assert.equal(f[1], 'fake/gpt-test')
  assert.equal(f[3], '0')   // exit code
  assert.equal(f[4], '11')  // input tokens from canned JSON
  assert.equal(f[5], '7')   // output tokens
})

test('ask.sh: non-JSON CLI output falls back to raw passthrough', async () => {
  const env = makeCliEnv()
  const r = await runScript(env, 'ask.sh', ['--model', 'gemini', 'say ok'],
    { FAKE_CLAUDE_MODE: 'raw' })
  assert.equal(r.code, 0, r.stderr)
  assert.equal(r.stdout.split('\n')[0], '[sidecar: fake/gemini-test]')
  assert.match(r.stdout, /plain non-json output/)
  // No parsed usage -> '?' token columns, but the run is still logged.
  const f = env.read(env.historyFile).trim().split('\n').pop().split('\t')
  assert.equal(f[4], '?')
  assert.equal(f[5], '?')
})

test('ask.sh: CLI failure with proxy still alive does NOT retry', async () => {
  const env = makeCliEnv()
  const r = await runScript(env, 'ask.sh', ['--model', 'gemini', 'say ok'],
    { FAKE_CLAUDE_MODE: 'fail' })
  assert.notEqual(r.code, 0)
  assert.match(r.stderr, /sub-Claude exited/)
  assert.doesNotMatch(r.stderr, /retrying once/)
  assert.equal(env.recordings('argv').length, 1)
})

test('ask.sh: dead proxy triggers exactly one restart-and-retry', { skip: !hasLsof() }, async () => {
  const env = makeCliEnv()
  const r = await runScript(env, 'ask.sh', ['--model', 'gemini', 'say ok'],
    { FAKE_CLAUDE_MODE: 'killproxy' })
  assert.equal(r.code, 0, r.stderr)
  assert.match(r.stderr, /proxy died mid-call — restarting and retrying once/)
  assert.match(r.stdout, /answer after retry/)
  assert.equal(env.recordings('argv').length, 2)
})

test('ask.sh: empty prompt and unknown flag exit 2 before booting anything', async () => {
  const env = makeCliEnv()
  const empty = await runScript(env, 'ask.sh', [])
  assert.equal(empty.code, 2)
  const flag = await runScript(env, 'ask.sh', ['--bogus', 'hi'])
  assert.equal(flag.code, 2)
  assert.equal(env.recordings('argv').length, 0)
})

// ---------- compare.sh ----------

test('compare.sh: parallel forks, labeled sections, distinct ports', async () => {
  const env = makeCliEnv()
  const r = await runScript(env, 'compare.sh', ['ping', 'gemini', 'gpt'])
  assert.equal(r.code, 0, r.stderr)
  assert.match(r.stdout, /^=== gemini ===$/m)
  assert.match(r.stdout, /^=== gpt ===$/m)
  assert.match(r.stdout, /\[sidecar: fake\/gemini-test\]/)
  assert.match(r.stdout, /\[sidecar: fake\/gpt-test\]/)
  const ports = env.recordings('baseurl').map(f => env.read(f).split(':').pop())
  assert.equal(ports.length, 2)
  assert.notEqual(ports[0], ports[1])
})

test('compare.sh: a failed fork reports inline without sinking the rest', async () => {
  const env = makeCliEnv()
  const r = await runScript(env, 'compare.sh', ['ping', 'gemini', 'nosuchvendor'])
  assert.equal(r.code, 0, r.stderr)  // >=1 fork succeeded
  assert.match(r.stdout, /^=== gemini ===$/m)
  assert.match(r.stdout, /^=== nosuchvendor \(FAILED rc=2\) ===$/m)
  assert.match(r.stdout, /no model alias for 'nosuchvendor'/)
})

test('compare.sh: fewer than two targets is a usage error', async () => {
  const env = makeCliEnv()
  const r = await runScript(env, 'compare.sh', ['ping', 'gemini'])
  assert.equal(r.code, 1)
  assert.match(r.stderr, /at least two models/)
})

// ---------- refresh-defaults.sh ----------

const CATALOG = JSON.stringify({
  data: [
    { id: 'fake/gemini-test', created: 100 },
    { id: 'google/gemini-newest', created: 300 },
    { id: 'google/gemini-older', created: 200 },
    { id: 'openai/gpt-something', created: 250 },
  ],
})

function writeCatalog(env) {
  const p = path.join(env.root, 'catalog.json')
  fs.writeFileSync(p, CATALOG)
  return p
}

test('refresh-defaults.sh: validates against the catalog and remaps the alias', async () => {
  const env = makeCliEnv()
  const catalog = writeCatalog(env)
  const r = await runScript(env, 'refresh-defaults.sh', ['gemini', 'google/gemini-newest'],
    { SIDECAR_CATALOG_FILE: catalog })
  assert.equal(r.code, 0, r.stderr)
  assert.match(env.read(env.defaultsFile), /^SIDECAR_MODEL_GEMINI="google\/gemini-newest"$/m)
  // The other alias is untouched.
  assert.match(env.read(env.defaultsFile), /^SIDECAR_MODEL_GPT="fake\/gpt-test"$/m)
})

test('refresh-defaults.sh: rejects a slug missing from the catalog', async () => {
  const env = makeCliEnv()
  const catalog = writeCatalog(env)
  const r = await runScript(env, 'refresh-defaults.sh', ['gemini', 'google/not-real'],
    { SIDECAR_CATALOG_FILE: catalog })
  assert.equal(r.code, 2)
  assert.match(r.stderr, /Unknown slug/)
  assert.match(env.read(env.defaultsFile), /^SIDECAR_MODEL_GEMINI="fake\/gemini-test"$/m)
})

test('refresh-defaults.sh: no-args view lists candidates newest-first', async () => {
  const env = makeCliEnv()
  const catalog = writeCatalog(env)
  const r = await runScript(env, 'refresh-defaults.sh', [], { SIDECAR_CATALOG_FILE: catalog })
  assert.equal(r.code, 0, r.stderr)
  assert.match(r.stdout, /SIDECAR_MODEL_GEMINI="fake\/gemini-test"/)
  const newest = r.stdout.indexOf('google/gemini-newest')
  const older = r.stdout.indexOf('google/gemini-older')
  assert.ok(newest !== -1 && older !== -1 && newest < older, 'newest candidate listed first')
})
