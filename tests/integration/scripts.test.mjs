import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const SCRIPTS = path.join(REPO, 'skills/sidecar/scripts')

// Fake keys, assembled at runtime so the repo's secret scanner
// (scripts/lib/check-secrets.sh) doesn't flag the literal prefix.
const FAKE_KEY = 'sk-or-' + 'v1-testkey1234'
const KEEP_KEY = 'sk-or-' + 'v1-keepme9999'

// Temp HOMEs created by makeEnv, removed in after() — tests must clean up
// after themselves (.claude/rules/testing.md); the host machine isn't ephemeral.
const tempHomes = []
after(() => {
  for (const h of tempHomes) fs.rmSync(h, { recursive: true, force: true })
})

// Build an isolated env: temp HOME with mnt/<folder>, stub bin on PATH.
function makeEnv({ folders = ['MyFolder'], catalog = ['test/model-a', 'test/model-b'] } = {}) {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-test-')))
  tempHomes.push(home)
  for (const f of folders) fs.mkdirSync(path.join(home, 'mnt', f), { recursive: true })
  const bin = path.join(home, 'bin')
  fs.mkdirSync(bin)
  fs.writeFileSync(path.join(bin, 'claude'), '#!/bin/sh\necho "claude-stub 0.0.0"\n', { mode: 0o755 })
  // curl stub: serves the model catalog for set-model.sh's validation call;
  // reports unreachable (000) for setup.sh's -w "%{http_code}" probe.
  // Arm order matters: setup.sh's probe URL also contains 'models', so the
  // http_code arm must come first or the probe would receive catalog JSON.
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

// Proxy-entry resolution: bundle.cjs preferred, bundle-min.cjs fallback
// (git-clone/marketplace installs have no bundle.cjs — it's gitignored).
const locateEntry = (env) =>
  run('bash', ['-c', 'source "$1"; echo "$SIDECAR_PROXY_ENTRY"', 'bash', path.join(SCRIPTS, '_locate.sh')], env)
    .stdout.trim()

function fakePluginDir(home, bundles) {
  const plugin = path.join(home, 'fake-plugin')
  fs.mkdirSync(path.join(plugin, 'proxy'), { recursive: true })
  for (const b of bundles) fs.writeFileSync(path.join(plugin, 'proxy', b), '// stub\n')
  return plugin
}

test('_locate: proxy entry prefers bundle.cjs when both bundles exist', () => {
  const { home, env } = makeEnv()
  const plugin = fakePluginDir(home, ['bundle.cjs', 'bundle-min.cjs'])
  assert.equal(locateEntry({ ...env, SIDECAR_PLUGIN_DIR: plugin }),
    path.join(plugin, 'proxy/bundle.cjs'))
})

test('_locate: proxy entry falls back to bundle-min.cjs in a git-clone install', () => {
  const { home, env } = makeEnv()
  const plugin = fakePluginDir(home, ['bundle-min.cjs'])     // no bundle.cjs, like a clone
  assert.equal(locateEntry({ ...env, SIDECAR_PLUGIN_DIR: plugin }),
    path.join(plugin, 'proxy/bundle-min.cjs'))
})

test('_locate: SIDECAR_BUNDLE_OVERRIDE beats both bundles', () => {
  const { home, env } = makeEnv()
  const plugin = fakePluginDir(home, ['bundle.cjs', 'bundle-min.cjs'])
  assert.equal(locateEntry({ ...env, SIDECAR_PLUGIN_DIR: plugin, SIDECAR_BUNDLE_OVERRIDE: '/hot/patched.cjs' }),
    '/hot/patched.cjs')
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
  const key = FAKE_KEY
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
  run('bash', [path.join(SCRIPTS, 'set-key.sh'), FAKE_KEY], e)
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
  run('bash', [path.join(SCRIPTS, 'set-key.sh'), FAKE_KEY], e)
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
  run('bash', [path.join(SCRIPTS, 'set-key.sh'), KEEP_KEY], e)
  const r2 = run('bash', [path.join(SCRIPTS, 'setup.sh')], e)
  assert.equal(r2.code, 0, r2.stderr)
  assert.ok(fs.readFileSync(path.join(state, '.env.local'), 'utf8').includes(KEEP_KEY))
})
