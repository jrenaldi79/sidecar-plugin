// Integration locks for the usage dashboard: usage.sh reports OpenRouter
// account balance + spend windows using ONLY the regular inference key.
// Per-model analytics are deliberately unsupported (OpenRouter gates them
// behind an admin-capable management key — see CHANGELOG 0.4.0).
// OpenRouter endpoints are served by a curl stub on PATH.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { SCRIPTS, FAKE_KEY, makeEnv, run, seededState, cleanupTempHomes } from '../helpers/script-env.mjs'

after(cleanupTempHomes)

const CREDITS_JSON = JSON.stringify({ data: { total_credits: 25, total_usage: 10.5 } })
const KEYINFO_JSON = JSON.stringify({ data: { label: 'or-key-label', limit: null, usage: 10.5, usage_daily: 0.42, usage_weekly: 1.5, usage_monthly: 4.2 } })

// curl stub: serves /credits and /key from fixtures and logs every
// invocation's args so tests can assert what was (and wasn't) called.
function stubUsageCurl(home) {
  fs.writeFileSync(path.join(home, 'bin/curl'), `#!/bin/sh
echo "$*" >> "$HOME/curl-args.log"
case "$*" in
  *credits*)  printf '%s' '${CREDITS_JSON}' ;;
  */api/v1/key*) printf '%s' '${KEYINFO_JSON}' ;;
  *) printf '000' ;;
esac
`, { mode: 0o755 })
}

function usageEnv() {
  const { home, env } = makeEnv()
  const state = seededState(home)
  const e = { ...env, SIDECAR_STATE_DIR: state }
  stubUsageCurl(home)
  run('bash', [path.join(SCRIPTS, 'set-key.sh'), FAKE_KEY], e)
  return { home, state, e }
}

test('usage: exits 1 with guidance when the API key is still the placeholder', () => {
  const { home, env } = makeEnv()
  const state = seededState(home)
  const r = run('bash', [path.join(SCRIPTS, 'usage.sh')], { ...env, SIDECAR_STATE_DIR: state })
  assert.equal(r.code, 1)
  assert.match(r.stderr, /OPENROUTER_API_KEY/)
})

test('usage --json: balance + spend from the regular key; nothing else', () => {
  const { home, e } = usageEnv()
  const r = run('bash', [path.join(SCRIPTS, 'usage.sh'), '--json'], e)
  assert.equal(r.code, 0, r.stderr)
  assert.ok(!r.stdout.includes(FAKE_KEY), 'key must never appear in output')
  const j = JSON.parse(r.stdout)
  assert.deepEqual(j, {
    credits: { total_purchased: 25, total_used: 10.5, balance: 14.5 },
    spend: { daily: 0.42, weekly: 1.5, monthly: 4.2, limit: null },
  })
  // the management-key concept must not resurface anywhere
  assert.ok(!/management/i.test(r.stdout + r.stderr))
  // only the two regular-key endpoints are called
  const argsLog = fs.readFileSync(path.join(home, 'curl-args.log'), 'utf8')
  assert.ok(!argsLog.includes('activity'), '/activity must never be called')
})

test('usage: human mode prints balance and spend windows', () => {
  const { e } = usageEnv()
  const r = run('bash', [path.join(SCRIPTS, 'usage.sh')], e)
  assert.equal(r.code, 0, r.stderr)
  assert.match(r.stdout, /balance:\s+\$14\.50/)
  assert.match(r.stdout, /today \$0\.42 \| this week \$1\.50 \| this month \$4\.20/)
  assert.ok(!/management/i.test(r.stdout + r.stderr))
})

test('set-key: --management flag is gone — treated as an invalid key, file untouched', () => {
  const { state, e } = usageEnv()
  const before = fs.readFileSync(path.join(state, '.env.local'), 'utf8')
  const r = run('bash', [path.join(SCRIPTS, 'set-key.sh'), '--management', FAKE_KEY], e)
  assert.equal(r.code, 3)
  assert.equal(fs.readFileSync(path.join(state, '.env.local'), 'utf8'), before)
  assert.ok(!before.includes('OPENROUTER_MANAGEMENT_KEY'))
})
