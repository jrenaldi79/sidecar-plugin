---
globs: ["**/*.sh"]
---
# Shell Script Conventions

- Start every script with `#!/usr/bin/env bash` and `set -u` (use `set -eu` unless the script must continue past failures, like `test.sh`).
- Quote every variable expansion: `"$var"`, `"$(cmd)"`. Unquoted expansions are the #1 shellcheck finding in this repo.
- Target **bash 3.2** compatibility — macOS ships bash 3.2 and Cowork sandboxes vary. No associative arrays (`declare -A`), no `${var,,}` lowercasing, no `mapfile`.
- Scripts must work on both BSD (macOS) and GNU (Linux sandbox) userlands: no `grep -P`, no `sed -i` without a suffix arg, no `readlink -f`.
- Resolve paths relative to the script, not the CWD: `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`.
- Shared discovery logic goes in `skills/sidecar/scripts/_locate.sh` — source it, don't duplicate it.
- Never `echo` secret values (API keys). Confirm presence/prefix only, as `test.sh` does.
- Suppress a shellcheck finding only with an inline `# shellcheck disable=SCXXXX` plus a reason; never blanket-disable.
- `shellcheck --severity=error` blocks commits; plain warnings are advisory but fix them in files you touch.
