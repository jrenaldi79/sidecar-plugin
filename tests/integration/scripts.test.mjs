import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { SCRIPTS, FAKE_KEY, KEEP_KEY, makeEnv, run, seededState, cleanupTempHomes } from '../helpers/script-env.mjs'

// Temp HOMEs created by makeEnv are removed in after() — tests must clean up
// after themselves (.claude/rules/testing.md); the host machine isn't ephemeral.
after(cleanupTempHomes)

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

test('_locate: host mode — no $HOME/mnt falls back to ~/.sidecar-state', () => {
  // Claude Code on a host has no Cowork mount layout at all.
  const { home, env } = makeEnv({ folders: [] })
  fs.rmSync(path.join(home, 'mnt'), { recursive: true, force: true })
  assert.equal(locate(env), path.join(home, '.sidecar-state'))
})

test('_locate: host mode — existing ~/.sidecar-state with .env.local is found', () => {
  const { home, env } = makeEnv({ folders: [] })
  fs.rmSync(path.join(home, 'mnt'), { recursive: true, force: true })
  fs.mkdirSync(path.join(home, '.sidecar-state'))
  fs.writeFileSync(path.join(home, '.sidecar-state/.env.local'), 'x=1\n')
  assert.equal(locate(env), path.join(home, '.sidecar-state'))
})

test('_locate: Cowork mnt state wins over host ~/.sidecar-state when both exist', () => {
  const { home, env } = makeEnv()
  fs.mkdirSync(path.join(home, 'mnt/MyFolder/sidecar-state'), { recursive: true })
  fs.writeFileSync(path.join(home, 'mnt/MyFolder/sidecar-state/.env.local'), 'x=1\n')
  fs.mkdirSync(path.join(home, '.sidecar-state'))
  fs.writeFileSync(path.join(home, '.sidecar-state/.env.local'), 'x=1\n')
  assert.equal(locate(env), path.join(home, 'mnt/MyFolder/sidecar-state'))
})

test('_locate: hard default when mnt exists but holds only system folders', () => {
  // Cowork-shaped env with nothing usable — keep the legacy hard default.
  const { home, env } = makeEnv({ folders: ['outputs', 'uploads'] })
  assert.equal(locate(env), path.join(home, 'mnt/ClaudeCowork/sidecar-state'))
})

// find-transcript: Cowork bind-mount first, host ~/.claude/projects second.
// Must use only BSD-compatible find (the GNU -printf form silently failed
// on macOS hosts).
const findTranscript = (env, ...args) =>
  run('bash', [path.join(SCRIPTS, 'find-transcript.sh'), ...args], env)

test('find-transcript: host mode — resolves ~/.claude/projects and newest jsonl', () => {
  const { home, env } = makeEnv({ folders: [] })
  fs.rmSync(path.join(home, 'mnt'), { recursive: true, force: true })
  const proj = path.join(home, '.claude/projects/-some-project')
  fs.mkdirSync(proj, { recursive: true })
  const past = new Date(Date.now() - 60_000)
  fs.writeFileSync(path.join(proj, 'older.jsonl'), '{}\n')
  fs.utimesSync(path.join(proj, 'older.jsonl'), past, past)
  fs.writeFileSync(path.join(proj, 'newer.jsonl'), '{}\n')
  assert.equal(findTranscript(env, '--dir').stdout.trim(), path.join(home, '.claude/projects'))
  assert.equal(findTranscript(env).stdout.trim(), path.join(proj, 'newer.jsonl'))
})

test('find-transcript: Cowork bind mount preferred over host dir', () => {
  const { home, env } = makeEnv({ folders: [] })
  const cowork = path.join(home, 'mnt/.claude/projects/p1')
  const host = path.join(home, '.claude/projects/p2')
  fs.mkdirSync(cowork, { recursive: true })
  fs.mkdirSync(host, { recursive: true })
  fs.writeFileSync(path.join(cowork, 'a.jsonl'), '{}\n')
  fs.writeFileSync(path.join(host, 'b.jsonl'), '{}\n')
  assert.equal(findTranscript(env, '--dir').stdout.trim(), path.join(home, 'mnt/.claude/projects'))
  assert.equal(findTranscript(env).stdout.trim(), path.join(cowork, 'a.jsonl'))
})

test('find-transcript: exits 1 with guidance when neither location exists', () => {
  const { home, env } = makeEnv({ folders: [] })
  fs.rmSync(path.join(home, 'mnt'), { recursive: true, force: true })
  const r = findTranscript(env)
  assert.equal(r.code, 1)
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
