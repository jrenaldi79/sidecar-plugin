# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**Sidecar** is a Claude Code/Cowork plugin that runs any OpenRouter-hosted LLM (Gemini, GPT, DeepSeek, etc.) as a `claude -p` subagent. A vendored local proxy (`127.0.0.1:3000`) accepts Anthropic `/v1/messages` requests and translates them to OpenAI `/v1/chat/completions` for OpenRouter — the Claude CLI thinks it's talking to Anthropic.

### Core Features

- **Fork & Fold**: fork a prompt to another model mid-session, fold the answer back into the main Claude context
- **Vendored proxy**: all deps pre-bundled into `bundle.cjs` via esbuild — no runtime `npm install` in ephemeral Cowork sandboxes
- **Marketplace install**: this repo doubles as a plugin marketplace (`/plugin marketplace add jrenaldi79/sidecar-plugin`)

---

## Essential Commands

```bash
bash build.sh                              # vendor deps, bundle proxy, zip -> ../sidecar.plugin
bash skills/sidecar/scripts/test.sh        # end-to-end verification (needs configured .env.local)
bash skills/sidecar/scripts/setup.sh       # idempotent first-run setup (creates state dir + .env.local)
bash skills/sidecar/scripts/list-models.sh # query live OpenRouter catalog
shellcheck $(git ls-files '*.sh')          # lint all shell scripts
```

### Enforcement (run by git hooks; can be run manually)

```bash
bash scripts/lib/check-secrets.sh          # scan staged files for API keys / private keys
bash scripts/lib/check-file-sizes.sh       # staged source files vs 300-line limit
bash scripts/lib/validate-docs.sh          # warn if source staged without CLAUDE.md
bash scripts/lib/validate-docs.sh --full   # verify paths in this file exist on disk
```

### Permissions (`.claude/settings.json`)

Destructive operations are denied outright: `rm -rf /`, `git push --force`, `git reset --hard`, pipe-to-shell, `npm publish`. Everything else prompts for approval.

---

## Architecture

```
"ask Gemini ..."  (skill trigger in parent Claude session)
  -> claude -p "<prompt>"  with ANTHROPIC_BASE_URL=http://127.0.0.1:3000
  -> wrapper.mjs (entry; sets undici dispatcher so fetch honors HTTP(S)_PROXY)
  -> anthropic-proxy: Anthropic /v1/messages  ->  OpenAI /v1/chat/completions
  -> OpenRouter (model from COMPLETION_MODEL in .env.local)
  -> response translated back; answer folded into parent context
```

Per-user state (`.env.local`: OpenRouter key, default model, port) lives in a `sidecar-state/` dir under the user's mounted folder, discovered by `_locate.sh`. The plugin itself is read-only at runtime.

---

## Directory Structure

```
.claude-plugin/plugin.json       # plugin manifest
.claude-plugin/marketplace.json  # marketplace listing for install-from-repo
build.sh                         # packages everything into ../sidecar.plugin
scripts/lib/                     # enforcement scripts (dev-only, excluded from plugin zip)
skills/sidecar/SKILL.md          # skill definition loaded by Cowork
skills/sidecar/.env.local.template
skills/sidecar/proxy/wrapper.mjs                 # entry point (HTTP_PROXY support)
skills/sidecar/proxy/anthropic-proxy-patched.mjs # vendored upstream, patched (exempt from limits)
skills/sidecar/proxy/bundle-min.cjs              # minified fallback bundle (generated, exempt)
skills/sidecar/scripts/          # setup/start/stop/status/test/ask/list-models/set-model/set-key
skills/sidecar/scripts/_locate.sh # shared state-dir discovery — source it, don't duplicate
```

---

## Code Quality Rules

Detailed rules auto-load from `.claude/rules/` (code-quality, shell conventions, tdd, testing) when working on matching paths. Headlines: 300-line file limit (mechanically enforced), 50-line function limit, shellcheck errors block commits.

### Documentation Sync (HARD RULE)

Any commit that adds, removes, or renames a file in `skills/sidecar/`, `scripts/`, or `build.sh` MUST update this file in the same commit. The pre-commit hook warns when it isn't staged.

---

## Git Hooks

Plain `.git/hooks/` shell scripts (no husky — this isn't an npm project at the root).

### pre-commit (fast)

| Step | What it does |
|------|--------------|
| `bash -n` | Syntax check on staged `.sh` files — blocks |
| `shellcheck --severity=error` | Blocks on errors; plain warnings printed but non-blocking |
| `scripts/lib/check-secrets.sh` | Blocks commits containing `sk-or-`/`sk-ant-`/AWS/GitHub keys or private key blocks |
| `scripts/lib/check-file-sizes.sh` | Blocks hand-written source files over 300 lines |
| `scripts/lib/validate-docs.sh` | Warns (never blocks) if source staged without CLAUDE.md |

### pre-push (thorough, SHA-cached)

Runs `bash -n` + shellcheck on ALL tracked scripts, `node --check` on proxy sources, JSON-parses the plugin manifests, and runs the `--full` docs drift check. On success, writes HEAD's SHA to `.checks-passed` (gitignored) so an unchanged HEAD skips the suite on the next push.

The real end-to-end test (`test.sh`) needs a live OpenRouter key and network, so it is NOT in the hooks — run it manually after touching the proxy or scripts.

---

## Critical Gotchas

- **`bundle.cjs` is gitignored and regenerated by `build.sh`; `bundle-min.cjs` IS tracked.** Never hand-edit either — patch `anthropic-proxy-patched.mjs` or `wrapper.mjs` and rebuild.
- **Cowork's plugin validator rejects `@` in zip paths** — that's why deps are esbuild-bundled instead of shipping `node_modules` (scoped packages = `@`-paths).
- **`build.sh` zip excludes any filename containing a space** (`'* *'` pattern). A file with a space silently vanishes from the shipped plugin.
- **Thinking models (Gemini 3.x Pro, GPT-5.5 reasoning) require `SIDECAR_STREAMING=true`** — the non-streaming path drops the `reasoning` field.
- **Target bash 3.2 + BSD userland**: scripts run on macOS hosts and Linux sandboxes. No `grep -P`, no `mapfile`, no `declare -A`, no `readlink -f`.
- **Cowork sandboxes lock down `/tmp`** — probe with `[ -w ]` before writing logs (see `test.sh`).
- **`.claude/*` is gitignored EXCEPT `settings.json` and `rules/`** — don't "fix" the gitignore back to `.claude/`.
- **`set -u` not `set -eu` in `test.sh`** is deliberate: it must run all checks and tally PASS/FAIL rather than abort on first failure.
- **Never echo API key values** — assert on the `sk-or-` prefix only.
- **The Cowork sandbox has no git** — repo operations happen on the host (see `SETUP-GIT.md`).

When you hit a non-obvious issue, add it here immediately — before ending the session. Memory is agent-local; CLAUDE.md is read by every session.

---

## Code Review Checklist

- [ ] Shell scripts pass `bash -n` and `shellcheck` (errors mandatory, warnings in touched files)
- [ ] No secrets in staged content (`scripts/lib/check-secrets.sh`)
- [ ] Hand-written files under 300 lines, functions under 50
- [ ] Works on both bash 3.2/BSD and Linux/GNU
- [ ] CLAUDE.md updated if files were added/removed/renamed
- [ ] `bash skills/sidecar/scripts/test.sh` run after proxy/script changes (manual, needs key)

---

## Writing Good CLAUDE.md Content

Every line here is part of the agent's prompt — make each one earn its place.

**Add**: commands that save re-discovery, gotchas that prevent repeat debugging, config quirks, ordering constraints, architecture knowledge not obvious from code.
**Don't add**: obvious code descriptions, generic best practices, one-off fixes, paragraphs where a line works.

New path-scoped rules go in `.claude/rules/*.md` with `globs:` frontmatter, not in this file. Enforcement hierarchy: mechanical (hooks/scripts) > path-scoped rules > CLAUDE.md prose.
