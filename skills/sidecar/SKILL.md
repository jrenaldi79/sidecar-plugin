---
name: sidecar
description: Run any OpenRouter-hosted LLM (Gemini, Claude, GPT, DeepSeek, etc.) as a Claude CLI subagent through a vendored local Anthropic-format proxy. Use when the user asks any of - "ask Gemini to ...", "what does ChatGPT think about ...", "have DeepSeek summarize ...", "how would Claude approach ...", "fork this to GPT", "get a second opinion from another model", "ask another model", "set up sidecar", "start sidecar", "test sidecar", "switch sidecar to X", "use sidecar with Y", "what sidecar models are available", or any phrasing that routes a prompt to a non-default LLM.
---

# Sidecar — call any OpenRouter LLM as a Claude CLI subagent

Sidecar serves two purposes: (a) one-time setup of the local proxy, and (b) on-demand "ask <vendor>" routing for prompts that should run through a model other than the user's default Claude. The proxy is vendored inside this plugin (no per-folder `npm install` required), so once the plugin is installed it's available in every Cowork session.

## How to invoke scripts

When a skill is loaded, the skill-loading system gives you the absolute path to this skill's base directory. **Use that path for all script invocations** — don't try to rediscover it via `find`. Throughout this document, `<SKILL_DIR>` is shorthand for that base directory; substitute it with the actual path when running commands. Scripts live at `<SKILL_DIR>/scripts/`, the vendored proxy bundle is at `<SKILL_DIR>/proxy/bundle.cjs`.

The user's `.env.local` lives in a writable state directory under whichever folder is connected to Cowork (default: first user-mounted folder, falling back to `ClaudeCowork`). Scripts auto-discover it via `_locate.sh`.

---

## Step 0 — Always start here: is Sidecar configured?

```bash
STATE=$(ls -d "$HOME/mnt"/*/.sidecar 2>/dev/null | head -1)
if [ -z "$STATE" ] || [ ! -f "$STATE/.env.local" ]; then echo "MODE=needs-setup"
elif ! grep -q '^OPENROUTER_API_KEY="sk-or-' "$STATE/.env.local" 2>/dev/null; then echo "MODE=needs-key"
else echo "MODE=ready"; fi
```

(Plugin presence is implicit — if you're running this skill, the plugin is installed.)

- **`needs-setup`** — no state dir / no `.env.local`. Run `setup.sh`, then prompt for the OpenRouter key.
- **`needs-key`** — `.env.local` present but the API key is still the placeholder. Use the Edit tool to set `OPENROUTER_API_KEY` (never echo the key).
- **`ready`** — go straight to **Use** for the user's actual request.

---

## Setup ("install sidecar", "set up sidecar")

1. **Run setup.**
   ```bash
   bash <SKILL_DIR>/scripts/setup.sh
   ```
   Idempotent. Verifies prereqs, ensures the vendored proxy bundle is intact, creates `<connected-folder>/.sidecar/` if missing, seeds `.env.local` from template, and probes outbound connectivity to `openrouter.ai`.

2. **Confirm the openrouter.ai allow-list.** Cowork sandboxes restrict outbound traffic to allow-listed domains. If `setup.sh` reported `openrouter.ai NOT reachable`, tell the user to:

   > Open Cowork Settings ▸ Capabilities ▸ Allowed domains and add `openrouter.ai` (or temporarily flip "Allow all domains" for testing). Then rerun `setup.sh` to confirm the probe passes.

   Without this step, every Sidecar request will fail with DNS errors regardless of the API key.

3. **Prompt for the OpenRouter key.** If `.env.local` still has `REPLACE_WITH_YOUR_OPENROUTER_KEY`, ask the user for their key (https://openrouter.ai/keys), then Edit the `.env.local` file. **Never** log or echo the key.

4. **Pick a default model** if the user has a preference:
   ```bash
   bash <SKILL_DIR>/scripts/list-models.sh gemini       # filter by vendor
   bash <SKILL_DIR>/scripts/set-model.sh <exact-slug>   # validates against catalog
   ```
   If no preference, leave the template default (`google/gemini-3-flash-preview`).

5. **Verify.**
   ```bash
   bash <SKILL_DIR>/scripts/test.sh
   ```
   8 checks. 8/8 PASS means everything works.

---

## Use — handling an "ask <vendor> to ..." request

### 1. Resolve the vendor → model

| User says | Default slug |
|---|---|
| Gemini, Google | `google/gemini-3-flash-preview` |
| Claude, Anthropic, Sonnet | `anthropic/claude-sonnet-4.6` |
| GPT, ChatGPT, OpenAI, GPT-4 | `openai/gpt-4o-mini` |
| DeepSeek | `deepseek/deepseek-v3.2` |
| Llama, Meta | `meta-llama/llama-3.3-70b-instruct` |

If the user names a *specific* model ("ask Claude Opus 4.6"), search the catalog:
```bash
bash <SKILL_DIR>/scripts/list-models.sh claude opus
```

### 2. Switch the proxy's model only if needed

```bash
STATE=$(ls -d "$HOME/mnt"/*/.sidecar 2>/dev/null | head -1)
set -a; source "$STATE/.env.local"; set +a
DESIRED="<resolved-slug>"
if [ "$COMPLETION_MODEL" != "$DESIRED" ]; then
  bash <SKILL_DIR>/scripts/set-model.sh "$DESIRED"
fi
```

### 3. Run the prompt — use `scripts/ask.sh`

`ask.sh` is the canonical entry point. It boots the proxy, locates the parent Cowork transcript, spawns sub-Claude with `--add-dir` access to that transcript plus a system-prompt hint, runs the prompt, then cleans up. Sub-Claude self-decides whether to consult the transcript based on the question.

```bash
bash <SKILL_DIR>/scripts/ask.sh "<the user's prompt verbatim>"
```

Or via stdin (better for prompts with quotes/special chars):

```bash
echo "<the user's prompt verbatim>" | bash <SKILL_DIR>/scripts/ask.sh
```

Pipe the output back to the user, prefaced by which model you actually routed to (so they know).

### 4. About the parent-transcript access

`ask.sh` always passes the parent's Cowork conversation jsonl as a readable directory (`--add-dir`) and tells sub-Claude *"only consult it if the prompt requires context."* Cost: ~one paragraph in sub-Claude's system prompt. Benefit: questions like "summarize what we just discussed" actually work without you (parent Claude) writing context manually.

If the user's prompt is clearly self-contained ("what is 13 × 17"), sub-Claude will ignore the transcript. If it's context-dependent, sub-Claude will Grep it and Read just the matching range — never the whole file.

### 5. Multi-turn within one ask

For a multi-step prompt, you can either:
- Put both steps in one `ask.sh` call — sub-Claude handles them in sequence.
- For full control, drop down to `<SKILL_DIR>/scripts/start.sh` + multiple `claude -p` calls in one bash invocation (proxy stays warm).

---

## Other workflows

### Switch default model ("switch sidecar to claude sonnet")

```bash
bash <SKILL_DIR>/scripts/list-models.sh claude sonnet
bash <SKILL_DIR>/scripts/set-model.sh anthropic/claude-sonnet-4.6
```

### Test ("test sidecar")

```bash
bash <SKILL_DIR>/scripts/test.sh
```

### Status ("what's sidecar configured for")

```bash
bash <SKILL_DIR>/scripts/status.sh
```

---

## Important behavior notes

- **Plugin is read-only.** State (.env.local) lives in the user's connected folder under `.sidecar/`, not inside the plugin. The plugin install caches a vendored proxy; it doesn't mutate at runtime.
- **Model identity is unreliable.** Models often hallucinate Claude/GPT regardless of what's actually configured. Authoritative source: the `model` field on a curl probe of `http://127.0.0.1:3000/v1/messages`, or the proxy log.
- **CLI's `--model` is cosmetic** when going through Sidecar — the proxy substitutes upstream using `COMPLETION_MODEL` / `REASONING_MODEL` from `.env.local`.
- **Provider allowlists.** Some OpenRouter models need specific providers (`novita`, `azure`). 404 "No allowed providers" → flip those on at https://openrouter.ai/settings/preferences.
- **Sandbox process lifetime.** Detached background processes die between bash calls — always do start/use/stop in a single bash invocation.
- **Mac-mount permissions.** The connected folder allows file creation but blocks `rm`/`unlink`. Scripts use redirect-truncate (`>`) instead of `mv` — don't change that pattern.
- **`/tmp` may not be writable.** In some Cowork sandboxes `/tmp` is owned by root and locked down. Scripts probe `[ -w "$HOME" ]` first and only fall through to `/tmp` if `$HOME` happens to be unwritable. Don't reorder those candidates.
- **Folder name doesn't have to be `ClaudeCowork`.** `_locate.sh` picks the first user-mounted, writable folder for state if no existing `.sidecar/.env.local` is found. Override with `SIDECAR_STATE_DIR=...` if you want a specific location.
- **Outbound network goes through HTTP_PROXY/HTTPS_PROXY** when set. The proxy bundle's `wrapper.mjs` installs a global undici dispatcher so Node `fetch()` honors those env vars. No-op when the env vars are unset.
- **Occasional crashes.** `anthropic-proxy` sometimes blows up on a partial JSON chunk from OpenRouter. Restart it. If it becomes a regular nuisance, pin the version in the vendored package.
