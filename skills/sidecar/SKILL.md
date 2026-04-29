---
name: sidecar
description: Run any OpenRouter-hosted LLM (Gemini, Claude, GPT, DeepSeek, etc.) as a Claude CLI subagent through a vendored local Anthropic-format proxy. Use when the user asks any of - "ask Gemini to ...", "what does ChatGPT think about ...", "have DeepSeek summarize ...", "how would Claude approach ...", "fork this to GPT", "get a second opinion from another model", "ask another model", "set up sidecar", "start sidecar", "test sidecar", "switch sidecar to X", "use sidecar with Y", "what sidecar models are available", or any phrasing that routes a prompt to a non-default LLM.
---

# Sidecar — call any OpenRouter LLM as a Claude CLI subagent

Sidecar serves two purposes: (a) one-time setup of the local proxy, and (b) on-demand "ask <vendor>" routing for prompts that should run through a model other than the user's default Claude. The proxy is vendored inside this plugin (no per-folder `npm install` required), so once the plugin is installed it's available in every Cowork session.

## How to invoke scripts

When a skill is loaded, the skill-loading system gives you the absolute path to this skill's base directory. **Use that path for all script invocations** — don't try to rediscover it via `find`. Throughout this document, `<SKILL_DIR>` is shorthand for that base directory; substitute it with the actual path when running commands. Scripts live at `<SKILL_DIR>/scripts/`, the vendored proxy bundle is at `<SKILL_DIR>/proxy/bundle.cjs`.

### Path translation in Cowork (read this before your first script call)

Cowork on **Windows** hands you a Windows path like `C:\Users\<user>\rpm\plugin_<ID>\skills\sidecar`. Bash runs in a Linux sandbox where the same plugin lives at `/sessions/<session>/mnt/.remote-plugins/plugin_<ID>/skills/sidecar/`. The `plugin_<ID>` segment is identical between the two — only the prefix changes. Translate the Windows path to the bash form once, before your first invocation, otherwise the first `setup.sh` call will fail with `No such file or directory`.

On Mac/Linux Cowork hosts the path is already in Linux form and no translation is needed.

### Tools you'll need (load up front, in one ToolSearch call)

Setup uses these deferred tools. Load them all in a single `ToolSearch` round-trip — not one at a time — to avoid stalls mid-flow:

- `mcp__workspace__bash` — every script invocation
- `mcp__visualize__read_me` + `mcp__visualize__show_widget` — the elicitation form for API-key + model
- `TaskCreate` / `TaskUpdate` — only if you plan to track progress (see Task tracking note below)

The user's `.env.local` lives in a writable state directory under whichever folder is connected to Cowork (default: first user-mounted folder, falling back to `ClaudeCowork`). Scripts auto-discover it via `_locate.sh`.

---

## Step 0 — Always start here: is Sidecar configured?

```bash
STATE=$(ls -d "$HOME/mnt"/*/sidecar-state "$HOME/mnt"/*/.sidecar 2>/dev/null | head -1)
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

### Happy path (scan this first)

The full happy path. Numbers tie to the detailed steps below — when in doubt, just run these in order:

```bash
# (1) Run setup: creates state dir + .env.local from template, probes connectivity
bash <SKILL_DIR>/scripts/setup.sh

# (2) If setup reported openrouter.ai NOT reachable, send the user to
#     Cowork Settings ▸ Capabilities ▸ Allowed domains, then rerun (1).

# (3) Render the elicitation form (mcp__visualize__show_widget). Collect:
#     - api_key:        sk-or-...
#     - default_model:  one of the four slugs in the cards table below

# (4) Write the key (NEVER use Edit/Write on .env.local — see virtiofs note):
echo "<api-key-from-form>" | bash <SKILL_DIR>/scripts/set-key.sh

# (5) Set the model AND verify in one bash call (chain with &&):
bash <SKILL_DIR>/scripts/set-model.sh <slug-from-form> && \
  bash <SKILL_DIR>/scripts/test.sh
```

**Batch where you can.** Any two scripts with a clear linear dependency belong in the same bash call — `set-model.sh && test.sh`, `setup.sh && cat <state>/.env.local`, etc. Each separate bash invocation is a tool round-trip; chains save them.

**Task tracking on this short flow.** The setup happy path is six steps and pure linear scripting. If you're going to track with `TaskCreate`, create all six tasks at the start in one batch — don't add tracking mid-flow, you'll spend more calls on bookkeeping than on the work. For most setups, skipping task tracking entirely is fine.

### Detailed steps

1. **Run setup.**
   ```bash
   bash <SKILL_DIR>/scripts/setup.sh
   ```
   Idempotent. Verifies prereqs, ensures the vendored proxy bundle is intact, creates `<connected-folder>/sidecar-state/` if missing, seeds `.env.local` from template, runs a writability probe on the state dir, and probes outbound connectivity to `openrouter.ai`.

2. **Confirm the openrouter.ai allow-list.** Cowork sandboxes restrict outbound traffic to allow-listed domains. If `setup.sh` reported `openrouter.ai NOT reachable`, tell the user to:

   > Open Cowork Settings ▸ Capabilities ▸ Allowed domains and add `openrouter.ai` (or temporarily flip "Allow all domains" for testing). Then rerun `setup.sh` to confirm the probe passes.

   Without this step, every Sidecar request will fail with DNS errors regardless of the API key.

3. **Collect the API key + default model via an interactive form. Use the EXACT cards specified below — do not improvise.**

   ⚠️ **Do NOT use model names you "know" from training data.** Your training data is older than the current OpenRouter catalog. **Specifically, do NOT show:** GPT-4, GPT-4o, GPT-4-turbo, Gemini 2.5 Pro, Gemini 1.5 Pro, Claude 3.5 Sonnet, Claude 3 Opus, or any other model not in the table below. Use the four slugs verbatim. If a slug appears unfamiliar to you, that's expected — it's newer than your training data.

   **Steps:**

   1. Call `mcp__visualize__read_me` with `modules: ["elicitation"]` to load the form-styling guide.
   2. Call `mcp__visualize__show_widget` with an elicitation form that has:
      - A `<textarea>` (monospace, `data-name="api_key"`) for the OpenRouter API key (pointing the user at https://openrouter.ai/keys).
      - A card-style `.elicit-pills` group (`data-name="default_model"`, `data-multi="false"`) with **EXACTLY THESE FOUR CARDS, IN ORDER, AND NO OTHERS**:

        | Card label | One-line description | `data-value` slug (use verbatim) |
        |---|---|---|
        | Gemini 3.1 Pro | Google's latest reasoning preview — strong on long context | `google/gemini-3.1-pro-preview` |
        | GPT-5.5 | OpenAI's current default — balanced speed and quality | `openai/gpt-5.5` |
        | DeepSeek V4 Flash | Cheap, fast, solid on code & reasoning | `deepseek/deepseek-v4-flash` |
        | Claude Sonnet 4.6 | Anthropic's mid-tier — closest to the parent Claude | `anthropic/claude-sonnet-4.6` |

   3. Parse the submitted form. Then:
      - Write the key via `bash <SKILL_DIR>/scripts/set-key.sh` (pipe the key through stdin: `echo "<key>" | bash <SKILL_DIR>/scripts/set-key.sh`). **Never** use the Edit/Write tools on `.env.local` — virtiofs/OneDrive backed mounts (Windows hosts) silently drop those edits. Always inject via bash redirect.
      - Set the model with `bash <SKILL_DIR>/scripts/set-model.sh <slug>` (validates against the live catalog).

4. **Only fall back from the four slugs above if `set-model.sh` actually rejects them as 404.** Don't pre-emptively "verify" against your own model knowledge — those four slugs are validated and current. The check that matters is `set-model.sh` calling OpenRouter's catalog. If (and only if) it returns "Unknown slug", run `bash <SKILL_DIR>/scripts/list-models.sh <vendor>` and pick the most recent match — and tell the user which slug you substituted and why.

5. **Verify.**
   ```bash
   bash <SKILL_DIR>/scripts/test.sh
   ```
   8 checks. 8/8 PASS means everything works.

---

## Use — handling an "ask <vendor> to ..." request

### 1. Resolve the vendor → model

This table is a *recommendation snapshot* (current as of April 2026). OpenRouter's catalog turns over; if a slug 404s, fall back to the most recent matching slug from `list-models.sh`. A quick web search for "OpenRouter <vendor> latest model" can confirm.

| User says | Default slug (Apr 2026) |
|---|---|
| Gemini, Google | `google/gemini-3.1-pro-preview` |
| Claude, Anthropic, Sonnet | `anthropic/claude-sonnet-4.6` |
| GPT, ChatGPT, OpenAI, GPT-5 | `openai/gpt-5.5` |
| DeepSeek | `deepseek/deepseek-v4-flash` |
| Llama, Meta | `meta-llama/llama-3.3-70b-instruct` |

If the user names a *specific* model ("ask Claude Opus 4.6"), search the catalog:
```bash
bash <SKILL_DIR>/scripts/list-models.sh claude opus
```

### 2. Switch the proxy's model only if needed

```bash
STATE=$(ls -d "$HOME/mnt"/*/sidecar-state "$HOME/mnt"/*/.sidecar 2>/dev/null | head -1)
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

- **Plugin is read-only.** State (.env.local) lives in the user's connected folder under `sidecar-state/` (or legacy `.sidecar/`), not inside the plugin. The plugin install caches a vendored proxy; it doesn't mutate at runtime.
- **Model identity is unreliable.** Models often hallucinate Claude/GPT regardless of what's actually configured. Authoritative source: the `model` field on a curl probe of `http://127.0.0.1:3000/v1/messages`, or the proxy log.
- **CLI's `--model` is cosmetic** when going through Sidecar — the proxy substitutes upstream using `COMPLETION_MODEL` / `REASONING_MODEL` from `.env.local`.
- **Provider allowlists.** Some OpenRouter models need specific providers (`novita`, `azure`). 404 "No allowed providers" → flip those on at https://openrouter.ai/settings/preferences.
- **Sandbox process lifetime.** Detached background processes die between bash calls — always do start/use/stop in a single bash invocation.
- **Mac-mount permissions.** The connected folder allows file creation but blocks `rm`/`unlink`. Scripts use redirect-truncate (`>`) instead of `mv` — don't change that pattern.
- **Windows-host virtiofs/OneDrive constraints.** When the connected folder is OneDrive-synced on a Windows host, every state-file write must go through bash:
  - `cp` produces files with NTFS ACLs the user-token Edit/Write tools can't modify (EPERM).
  - `sed -i` triggers OneDrive's delete-and-recreate sync, which then deletes the new file.
  - Windows-side writes to a file aren't visible to bash until the inode is touched from the Linux side (virtiofs page cache staleness).
  
  **Rule of thumb:** never use Edit/Write tools on anything inside `sidecar-state/` (or legacy `.sidecar/`) — always use the provided scripts (`set-key.sh`, `set-model.sh`) which write via bash redirect.
- **`/tmp` may not be writable.** In some Cowork sandboxes `/tmp` is owned by root and locked down. Scripts probe `[ -w "$HOME" ]` first and only fall through to `/tmp` if `$HOME` happens to be unwritable. Don't reorder those candidates.
- **Folder name doesn't have to be `ClaudeCowork`.** `_locate.sh` picks the first user-mounted, writable folder and creates `sidecar-state/` inside it if no existing state dir is found. Override with `SIDECAR_STATE_DIR=...` if you want a specific location. The dir is named `sidecar-state` (no leading dot) because dotfile names break on Windows + virtiofs + OneDrive.
- **Outbound network goes through HTTP_PROXY/HTTPS_PROXY** when set. The proxy bundle's `wrapper.mjs` installs a global undici dispatcher so Node `fetch()` honors those env vars. No-op when the env vars are unset.
- **Occasional crashes.** `anthropic-proxy` sometimes blows up on a partial JSON chunk from OpenRouter. Restart it. If it becomes a regular nuisance, pin the version in the vendored package.
