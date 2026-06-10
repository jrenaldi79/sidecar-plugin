---
globs: ["skills/**/*.sh", "skills/**/*.mjs", "scripts/**", "build.sh"]
---
# Code Quality Rules

## File Size Limits (HARD LIMITS)

| Entity | Max Lines | Action If Exceeded |
|--------|-----------|-------------------|
| **Any hand-written file** | 300 lines | MUST refactor immediately |
| **Any function** | 50 lines | MUST break into smaller functions |

The 300-line limit is mechanically enforced by `scripts/lib/check-file-sizes.sh` in the pre-commit hook. Vendored proxy artifacts (`bundle*.cjs`, `anthropic-proxy-patched.mjs`) are exempt — they are upstream code, not authored here.

## Documentation Sync (HARD RULE)

Any commit that adds, removes, or renames a file in `skills/sidecar/scripts/`, `skills/sidecar/proxy/`, or `scripts/` MUST include a CLAUDE.md update in the same commit. The pre-commit hook warns if CLAUDE.md is not staged alongside tracked file changes.

## Complexity Red Flags

**STOP and refactor immediately if you see:**

- **>5 nested if/else statements** -> Extract to separate functions
- **>3 levels of nested case/loop in a shell script** -> Split into helper functions
- **Duplicate logic across scripts** -> Extract to a shared helper (pattern: `_locate.sh`)

## Code Quality Monitoring

```bash
# Line counts of hand-written source (target <300)
git ls-files '*.sh' '*.mjs' | grep -v -e bundle -e anthropic-proxy-patched | xargs wc -l | sort -n
```
