// Integration locks for the 0.3.0 usage dashboard: usage.sh (OpenRouter
// account balance / spend / per-model activity) and set-key.sh --management.
// All OpenRouter endpoints are served by a curl stub on PATH.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { SCRIPTS, FAKE_KEY, makeEnv, run, seededState, cleanupTempHomes } from '../helpers/script-env.mjs'

after(cleanupTempHomes)

// Assembled at runtime so check-secrets.sh doesn't flag the literal prefix.
const MGMT_KEY = 'sk-or-' + 'v1-mgmtkey5678'

const CREDITS_JSON = JSON.stringify({ data: { total_credits: 25, total_usage: 10.5 } })
const KEYINFO_JSON = JSON.stringify({ data: { label: 'or-key-label', limit: null, usage: 10.5, usage_daily: 0.42, usage_weekly: 1.5, usage_monthly: 4.2 } })
const ACTIVITY_JSON = JSON.stringify({ data: [
  { date: '2026-06-07', model: 'google/gemini-3.1-pro-preview', usage: 1.25, requests: 10, prompt_tokens: 50000, completion_tokens: 8000, reasoning_tokens: 2000 },
  { date: '2026-06-08', model: 'google/gemini-3.1-pro-preview', usage: 0.75, requests: 5, prompt_tokens: 30000, completion_tokens: 4000, reasoning_tokens: 1000 },
  { date: '2026-06-08', model: 'openai/gpt-5.5', usage: 3.0, requests: 2, prompt_tokens: 10000, completion_tokens: 2000, reasoning_tokens: 0 },
] })

// curl stub for usage tests: serves the three OpenRouter endpoints from
// fixtures and logs every invocation's args (incl. auth header) so tests can
// assert which key authenticated which endpoint.
function stubUsageCurl(home) {
  fs.writeFileSync(path.join(home, 'bin/curl'), `#!/bin/sh
echo "$*" >> "$HOME/curl-args.log"
case "$*" in
  *activity*) printf '%s' '${ACTIVITY_JSON}' ;;
  *credits*)  printf '%s' '${CREDITS_JSON}' ;;
  */api/v1/key*) printf '%s' '${KEYINFO_JSON}' ;;
  *) printf '000' ;;
esac
`, { mode: 0o755 })
}

function usageEnv({ managementKey = false } = {}) {
  const { home, env } = makeEnv()
  const state = seededState(home)
  const e = { ...env, SIDECAR_STATE_DIR: state }
  stubUsageCurl(home)
  run('bash', [path.join(SCRIPTS, 'set-key.sh'), FAKE_KEY], e)
  if (managementKey) run('bash', [path.join(SCRIPTS, 'set-key.sh'), '--management', MGMT_KEY], e)
  return { home, state, e }
}

test('set-key --management: writes OPENROUTER_MANAGEMENT_KEY, leaves API key intact, never echoes', () => {
  const { state, e } = usageEnv()
  const r = run('bash', [path.join(SCRIPTS, 'set-key.sh'), '--management'], e, { input: MGMT_KEY + '\n' })
  assert.equal(r.code, 0, r.stderr)
  assert.ok(!r.stdout.includes(MGMT_KEY) && !r.stderr.includes(MGMT_KEY), 'management key must never be echoed')
  const f = fs.readFileSync(path.join(state, '.env.local'), 'utf8')
  assert.match(f, new RegExp(`^OPENROUTER_MANAGEMENT_KEY="${MGMT_KEY}"$`, 'm'))
  assert.match(f, new RegExp(`^OPENROUTER_API_KEY="${FAKE_KEY}"$`, 'm'))
})

test('usage: exits 1 with guidance when the API key is still the placeholder', () => {
  const { home, env } = makeEnv()
  const state = seededState(home)
  const r = run('bash', [path.join(SCRIPTS, 'usage.sh')], { ...env, SIDECAR_STATE_DIR: state })
  assert.equal(r.code, 1)
  assert.match(r.stderr, /OPENROUTER_API_KEY/)
})

test('usage --json: balance + spend from the regular key; activity unavailable with hint', () => {
  const { e } = usageEnv()
  const r = run('bash', [path.join(SCRIPTS, 'usage.sh'), '--json'], e)
  assert.equal(r.code, 0, r.stderr)
  assert.ok(!r.stdout.includes(FAKE_KEY), 'key must never appear in output')
  const j = JSON.parse(r.stdout)
  assert.equal(j.credits.total_purchased, 25)
  assert.equal(j.credits.total_used, 10.5)
  assert.equal(j.credits.balance, 14.5)
  assert.equal(j.spend.daily, 0.42)
  assert.equal(j.spend.weekly, 1.5)
  assert.equal(j.spend.monthly, 4.2)
  assert.equal(j.activity.available, false)
  assert.match(j.activity.hint, /management key/i)
})

test('usage --json: management key unlocks per-model and per-date rollups', () => {
  const { home, e } = usageEnv({ managementKey: true })
  const r = run('bash', [path.join(SCRIPTS, 'usage.sh'), '--json'], e)
  assert.equal(r.code, 0, r.stderr)
  assert.ok(!r.stdout.includes(MGMT_KEY), 'management key must never appear in output')
  const j = JSON.parse(r.stdout)
  assert.equal(j.activity.available, true)
  // by_model: summed across dates, sorted by cost descending
  assert.equal(j.activity.by_model[0].model, 'openai/gpt-5.5')
  assert.equal(j.activity.by_model[0].usage, 3.0)
  assert.equal(j.activity.by_model[1].model, 'google/gemini-3.1-pro-preview')
  assert.equal(j.activity.by_model[1].usage, 2.0)
  assert.equal(j.activity.by_model[1].requests, 15)
  assert.equal(j.activity.by_model[1].prompt_tokens, 80000)
  // by_date: chronological
  assert.deepEqual(j.activity.by_date.map(d => d.date), ['2026-06-07', '2026-06-08'])
  assert.equal(j.activity.by_date[1].usage, 3.75)
  // raw rows preserved for time-series charts
  assert.equal(j.activity.rows.length, 3)
  // the management key authenticated /activity; the regular key did not
  const argsLog = fs.readFileSync(path.join(home, 'curl-args.log'), 'utf8')
  const activityCall = argsLog.split('\n').find(l => l.includes('activity'))
  assert.ok(activityCall.includes(MGMT_KEY), '/activity must use the management key')
  assert.ok(!activityCall.includes(FAKE_KEY), '/activity must not use the inference key')
})

test('usage: human mode prints balance, spend, and top models', () => {
  const { e } = usageEnv({ managementKey: true })
  const r = run('bash', [path.join(SCRIPTS, 'usage.sh')], e)
  assert.equal(r.code, 0, r.stderr)
  assert.match(r.stdout, /balance:\s+\$14\.50/)
  assert.match(r.stdout, /openai\/gpt-5\.5/)
})
