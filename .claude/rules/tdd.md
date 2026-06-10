---
globs: ["skills/**/*.sh", "skills/**/*.mjs", "scripts/**"]
---
# MANDATORY: Test-First Discipline

This repo's "test suite" is `skills/sidecar/scripts/test.sh` (end-to-end, needs an OpenRouter key) plus the static checks in the git hooks (`bash -n`, shellcheck, `node --check`).

**EVERY bug fix MUST start by reproducing the bug** — run the failing command or script and capture the actual error output before editing anything.

## Process

1. **Reproduce (Red)**: run the failing invocation; confirm and record the exact failure. For new script behavior, write the verification command first (a `test.sh` check, or a one-off invocation with expected output) and confirm it fails.
2. **Fix (Green)**: implement the minimal change that makes the verification pass.
3. **Refactor**: clean up; re-run the verification after each change.
4. **Validate**: run `bash -n` + `shellcheck` on every touched script, and `bash skills/sidecar/scripts/test.sh` if the proxy or scripts changed and a key is configured.
5. **Docs**: if files were added/removed/renamed, update CLAUDE.md in the same commit (pre-commit hook warns).

## Red Flags — STOP immediately if:

- Editing proxy or script files before reproducing the reported failure
- Theorizing about root cause without confirming it against actual output
- Claiming a fix works without re-running the failing invocation
- Adding a `test.sh` check that passes on the unfixed code

## When this can be relaxed

Documentation-only changes (`*.md`) and comment-only edits. Bug fixes are NEVER exempt — always reproduce first.
