---
globs: ["skills/sidecar/scripts/test.sh", "**/*.test.*"]
---
# Testing Patterns

## Test layers in this repo

- **Static (every commit, via hooks)**: `bash -n`, `shellcheck --severity=error`, `node --check` on proxy sources, JSON manifest parsing.
- **End-to-end (manual)**: `bash skills/sidecar/scripts/test.sh` — boots the proxy, makes a real OpenRouter call. Requires a configured `.env.local` with a valid `sk-or-` key.

## Best practices

- `test.sh` uses `set -u` (not `-e`) deliberately — it must run ALL checks and report a PASS/FAIL tally, not abort on the first failure. Keep new checks in that style: `pass`/`fail` helpers, never bare `exit` mid-suite.
- New checks must clean up after themselves (kill spawned proxies, remove temp logs) — sessions are ephemeral but the host machine isn't.
- Probe writability with `[ -w ]` before writing logs; sandboxes lock down `/tmp`.
- Never print API key values in test output — assert on prefix (`sk-or-`) only.
