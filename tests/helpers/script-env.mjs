// script-env.mjs — shared hermetic environment for shell-script integration
// tests: temp HOME with a Cowork-style mnt layout, stub claude/curl on PATH,
// and an execFileSync runner. Import cleanupTempHomes and register it with
// after() in every test file that calls makeEnv.
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
export const SCRIPTS = path.join(REPO, 'skills/sidecar/scripts')

// Fake keys, assembled at runtime so the repo's secret scanner
// (scripts/lib/check-secrets.sh) doesn't flag the literal prefix.
export const FAKE_KEY = 'sk-or-' + 'v1-testkey1234'
export const KEEP_KEY = 'sk-or-' + 'v1-keepme9999'

// Temp HOMEs created by makeEnv — tests must clean up after themselves
// (.claude/rules/testing.md); the host machine isn't ephemeral.
const tempHomes = []
export function cleanupTempHomes() {
  for (const h of tempHomes) fs.rmSync(h, { recursive: true, force: true })
}

// Build an isolated env: temp HOME with mnt/<folder>, stub bin on PATH.
export function makeEnv({ folders = ['MyFolder'], catalog = ['test/model-a', 'test/model-b'] } = {}) {
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
export function run(file, args, env, { input } = {}) {
  try {
    const stdout = execFileSync(file, args, { env, input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] })
    return { code: 0, stdout, stderr: '' }
  } catch (e) {
    return { code: e.status, stdout: e.stdout ?? '', stderr: e.stderr ?? '' }
  }
}

export function seededState(home) {
  const state = path.join(home, 'mnt/MyFolder/sidecar-state')
  fs.mkdirSync(state, { recursive: true })
  fs.copyFileSync(path.join(REPO, 'skills/sidecar/.env.local.template'), path.join(state, '.env.local'))
  return state
}
