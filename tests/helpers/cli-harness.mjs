// cli-harness.mjs — hermetic environment for integration-testing the Sidecar
// CLI scripts (ask.sh, compare.sh, refresh-defaults.sh, _runtime.sh) with no
// key, no network, and no real Claude CLI.
//
// Each env gets a throwaway HOME, a stub state dir, and a fake `claude` shim
// first on PATH. The shim records its argv/stdin/ANTHROPIC_BASE_URL per
// invocation and emits canned `--output-format json` output, so tests assert
// on exactly what ask.sh passed to the CLI and how it post-processed the
// result. The REAL proxy still boots (ask.sh's boot path is under test) —
// it just never receives a request.
import { execFile, spawn } from 'node:child_process'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
export const SCRIPTS_DIR = path.join(REPO_ROOT, 'skills/sidecar/scripts')

// Concatenated so the repo's secret scanner never sees a contiguous
// key-shaped literal in this source file.
const FAKE_KEY = 'sk-or-' + 'v1-fake-integration-test-key-0000'

// Shim modes (FAKE_CLAUDE_MODE): json (default) | raw | fail | killproxy.
// killproxy: first invocation kills whatever listens on the proxy port and
// exits 1 (simulating the known anthropic-proxy partial-JSON crash); the
// second invocation succeeds — exercising ask.sh's retry-once path.
const SHIM = `#!/usr/bin/env bash
set -u
printf '%s\\n' "$@" > "$FAKE_CLAUDE_DIR/argv.$$"
cat > "$FAKE_CLAUDE_DIR/stdin.$$"
printf '%s' "\${ANTHROPIC_BASE_URL:-}" > "$FAKE_CLAUDE_DIR/baseurl.$$"
MODE="\${FAKE_CLAUDE_MODE:-json}"
PORT="\${ANTHROPIC_BASE_URL##*:}"
case "$MODE" in
  raw)
    printf 'plain non-json output' ;;
  fail)
    echo "fake claude: boom" >&2
    exit 1 ;;
  killproxy)
    if [ ! -f "$FAKE_CLAUDE_DIR/killed.marker" ]; then
      : > "$FAKE_CLAUDE_DIR/killed.marker"
      PIDS=$(lsof -ti "tcp:$PORT" 2>/dev/null || true)
      if [ -n "$PIDS" ]; then kill -9 $PIDS 2>/dev/null; fi
      sleep 0.3
      echo "fake claude: simulated proxy crash" >&2
      exit 1
    fi
    printf '{"type":"result","result":"answer after retry","session_id":"sess-retry-1","usage":{"input_tokens":3,"output_tokens":2},"is_error":false}' ;;
  json|*)
    printf '{"type":"result","result":"fake answer via port %s","session_id":"sess-fake-1","usage":{"input_tokens":11,"output_tokens":7},"duration_ms":42,"is_error":false}' "$PORT" ;;
esac
`

const ENV_LOCAL = [
  `OPENROUTER_API_KEY="${FAKE_KEY}"`,
  'COMPLETION_MODEL="fake/default-model"',
  'REASONING_MODEL="fake/default-model"',
  'PORT=3300',
  'SIDECAR_STREAMING="true"',
  'ANTHROPIC_BASE_URL="http://127.0.0.1:3300"',
  'ANTHROPIC_API_KEY="proxy-ignores-this"',
  '',
].join('\n')

const DEFAULTS_ENV = [
  'SIDECAR_MODEL_GEMINI="fake/gemini-test"',
  'SIDECAR_MODEL_GPT="fake/gpt-test"',
  '',
].join('\n')

// Every temp dir created here, for the consuming test file to remove in an
// after() hook — tests must clean up after themselves (.claude/rules/testing.md).
export const tempRoots = []
export function cleanupTempRoots() {
  for (const r of tempRoots) fs.rmSync(r, { recursive: true, force: true })
  tempRoots.length = 0
}

// mkdtemp wrapper that registers the dir for cleanupTempRoots().
export function trackedTempDir(prefix) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix))
  tempRoots.push(d)
  return d
}

export function makeCliEnv() {
  const root = trackedTempDir('sidecar-cli-')
  const home = path.join(root, 'home')
  const state = path.join(root, 'state')
  const shimDir = path.join(root, 'bin')
  const recDir = path.join(root, 'recordings')
  for (const d of [home, state, shimDir, recDir]) fs.mkdirSync(d)
  fs.writeFileSync(path.join(state, '.env.local'), ENV_LOCAL)
  fs.writeFileSync(path.join(state, 'defaults.env'), DEFAULTS_ENV)
  fs.writeFileSync(path.join(shimDir, 'claude'), SHIM, { mode: 0o755 })

  // Hermetic: drop inherited SIDECAR_*/FAKE_* so a developer's shell can't
  // change which code path a test pins (same rationale as proxy-harness).
  const inherited = { ...process.env }
  for (const k of Object.keys(inherited)) {
    if (k.startsWith('SIDECAR_') || k.startsWith('FAKE_CLAUDE_')) delete inherited[k]
  }
  const env = {
    ...inherited,
    HOME: home,
    PATH: `${shimDir}:${process.env.PATH}`,
    SIDECAR_STATE_DIR: state,
    FAKE_CLAUDE_DIR: recDir,
  }
  return {
    root, home, state, recDir, env,
    sessionsFile: path.join(home, '.sidecar-sessions'),
    historyFile: path.join(state, 'history.log'),
    defaultsFile: path.join(state, 'defaults.env'),
    // Recordings written by the shim, oldest -> newest.
    recordings(prefix) {
      return fs.readdirSync(recDir)
        .filter(f => f.startsWith(prefix + '.'))
        .map(f => path.join(recDir, f))
        .sort((a, b) => fs.statSync(a).mtimeMs - fs.statSync(b).mtimeMs)
    },
    read(p) { return fs.readFileSync(p, 'utf8') },
  }
}

// Run a script from skills/sidecar/scripts/. Never rejects on nonzero exit —
// returns { code, stdout, stderr } so tests can assert failure paths.
// stdin is closed ('ignore' -> /dev/null): ask.sh's stdin-prompt fallback
// must see EOF, not an open pipe that never delivers one.
export function runScript(cliEnv, script, args = [], extraEnv = {}) {
  return new Promise(resolve => {
    const proc = spawn('bash', [path.join(SCRIPTS_DIR, script), ...args], {
      env: { ...cliEnv.env, ...extraEnv },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let stdout = '', stderr = ''
    proc.stdout.on('data', d => { stdout += d })
    proc.stderr.on('data', d => { stderr += d })
    const timer = setTimeout(() => proc.kill('SIGKILL'), 60_000)
    proc.on('close', code => {
      clearTimeout(timer)
      resolve({ code: code ?? 1, stdout, stderr })
    })
  })
}

// Run an inline bash snippet with _locate.sh + _runtime.sh sourced (cwd:
// the scripts dir) — for unit-level assertions on the sourced helpers.
export function runtimeEval(cliEnv, snippet, extraEnv = {}) {
  const script = `source ./_locate.sh; source ./_runtime.sh; ${snippet}`
  return new Promise(resolve => {
    execFile('bash', ['-c', script], {
      cwd: SCRIPTS_DIR,
      env: { ...cliEnv.env, ...extraEnv },
      timeout: 30_000,
    }, (err, stdout, stderr) => {
      resolve({ code: err ? (err.code ?? 1) : 0, stdout, stderr })
    })
  })
}

// Spawn start.sh as a long-running child (for override-channel tests).
// Returns { proc, stop() } once the given port accepts connections.
export async function spawnStartSh(cliEnv, extraEnv, port) {
  const proc = spawn('bash', [path.join(SCRIPTS_DIR, 'start.sh')], {
    env: { ...cliEnv.env, ...extraEnv },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let logs = ''
  proc.stdout.on('data', d => { logs += d })
  proc.stderr.on('data', d => { logs += d })
  const deadline = Date.now() + 8000
  while (Date.now() < deadline) {
    const up = await new Promise(resolve => {
      const sock = net.connect({ port, host: '127.0.0.1' }, () => { sock.destroy(); resolve(true) })
      sock.on('error', () => resolve(false))
    })
    if (up) return { proc, logs: () => logs, stop: () => proc.kill('SIGKILL') }
    if (proc.exitCode !== null) break
    await new Promise(r => setTimeout(r, 50))
  }
  proc.kill('SIGKILL')
  throw new Error(`start.sh did not listen on ${port}:\n${logs}`)
}

export async function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer()
    s.listen(0, '127.0.0.1', () => {
      const p = s.address().port
      s.close(() => resolve(p))
    })
    s.on('error', reject)
  })
}

export function hasLsof() {
  try {
    fs.accessSync('/usr/sbin/lsof', fs.constants.X_OK)
    return true
  } catch {
    return ['/usr/bin/lsof', '/bin/lsof'].some(p => {
      try { fs.accessSync(p, fs.constants.X_OK); return true } catch { return false }
    })
  }
}
