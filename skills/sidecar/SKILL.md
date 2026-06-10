---
name: sidecar
description: Run any OpenRouter-hosted LLM (Gemini, GPT, DeepSeek, Grok, etc.) as a Claude CLI subagent through a vendored local Anthropic-format proxy. Use when the user asks any of - "ask Gemini to ...", "what does ChatGPT think about ...", "have DeepSeek summarize ...", "fork this to GPT", "get a second opinion from another model", "ask another model", "compare models on X", "ask Gemini AND GPT", "ask Gemini a follow-up", "set up sidecar", "start sidecar", "test sidecar", "switch sidecar to X", "use sidecar with Y", "what sidecar models are available", "what has sidecar cost me", "what's my openrouter balance", "how am I using my credits", "visualize my spend", "what can sidecar do", "sidecar help", "how do I use sidecar", "explain sidecar", or any phrasing that routes a prompt to a non-default LLM or asks what Sidecar is.
---

# Sidecar — call any OpenRouter LLM as a Claude CLI subagent

Sidecar serves two purposes: (a) one-time setup of the local proxy, and (b) on-demand "ask <vendor>" routing for prompts that should run through a model other than the user's default Claude. The proxy is vendored inside this plugin (no per-folder `npm install` required), so once the plugin is installed it's available in every session.

## Two environments — detect once, then branch

Sidecar runs in **Cowork** (Linux sandbox VM, mount layout under `$HOME/mnt`) and in **Claude Code** (directly on the host). Detect with one check — `[ -d "$HOME/mnt" ]` → Cowork, otherwise Claude Code — and apply these differences:

| | Cowork | Claude Code |
|---|---|---|
| State dir | `<connected-folder>/sidecar-state/` | `~/.sidecar-state/` |
| Bash tool | `mcp__workspace__bash`, ~45s ceiling | built-in `Bash`, generous/configurable timeout |
| Long calls | `run_in_background: true` + TaskOutput (mandatory for compare.sh) | same pattern works; ceiling rarely bites |
| Key/model collection | `mcp__visualize` elicitation form (exact cards below) | no visualize tools — use `AskUserQuestion` for the model pick and ask the user to paste the key in chat, then pipe it to `set-key.sh` |
| Network | needs `openrouter.ai` on the Settings ▸ Capabilities allow-list | no allow-list; skip that step |
| `timeout(1)` | always present | stock macOS lacks it — ask.sh warns and runs unguarded (`brew install coreutils` fixes) |
| Path translation | Windows hosts need the prefix swap below | not applicable |

Scripts are environment-agnostic — `_locate.sh` and `find-transcript.sh` resolve the right locations automatically in both. Everything else in this document applies to both environments unless marked Cowork-only.

## How to invoke scripts

When a skill is loaded, the skill-loading system gives you the absolute path to this skill's base directory. **Use that path for all script invocations** — don't try to rediscover it via `find`. Throughout this document, `<SKILL_DIR>` is shorthand for that base directory; substitute it with the actual path when running commands. Scripts live at `<SKILL_DIR>/scripts/`, the vendored proxy bundle is at `<SKILL_DIR>/proxy/bundle.cjs`.

### Path translation in Cowork (Cowork-only — read before your first script call)

Cowork on **Windows** hands you a Windows path like `C:\Users\<user>\rpm\plugin_<ID>\skills\sidecar`. Bash runs in a Linux sandbox where the same plugin lives at `/sessions/<session>/mnt/.remote-plugins/plugin_<ID>/skills/sidecar/`. The `plugin_<ID>` segment is identical between the two — only the prefix changes. Translate the Windows path to the bash form once, before your first invocation, otherwise the first `setup.sh` call will fail with `No such file or directory`.

On Mac/Linux Cowork hosts the path is already in Linux form and no translation is needed.

### Tools you'll need (load up front, in one ToolSearch call)

Setup uses these deferred tools. Load them all in a single `ToolSearch` round-trip — not one at a time — to avoid stalls mid-flow:

- `mcp__workspace__bash` (Cowork) — every script invocation; in Claude Code the built-in `Bash` tool is already available
- `mcp__visualize__read_me` + `mcp__visualize__show_widget` (Cowork) — the elicitation form for API-key + model; absent in Claude Code (use `AskUserQuestion` + chat instead)
- `TaskCreate` / `TaskUpdate` — only if you plan to track progress (see Task tracking note below)

The user's `.env.local` lives in a writable state directory — under the connected folder in Cowork, `~/.sidecar-state/` in Claude Code. Scripts auto-discover it via `_locate.sh`; `SIDECAR_STATE_DIR` overrides everywhere.

---

## Step 0 — Always start here: is Sidecar configured?

**Exception — discovery requests skip the config gate.** If the user is asking what Sidecar *is* or *can do* ("what can sidecar do", "sidecar help", "how do I use this") rather than asking to run something, go to **Help mode** below; run the config check only to report status at the end of the tour.

```bash
# Covers both environments: Cowork mounts AND Claude Code's ~/.sidecar-state.
STATE=$(ls -d "$HOME/mnt"/*/sidecar-state "$HOME/mnt"/*/.sidecar "$HOME/.sidecar-state" 2>/dev/null | head -1)
if [ -z "$STATE" ] || [ ! -f "$STATE/.env.local" ]; then echo "MODE=needs-setup"
elif ! grep -q '^OPENROUTER_API_KEY="sk-or-' "$STATE/.env.local" 2>/dev/null; then echo "MODE=needs-key"
else echo "MODE=ready"; fi
```

(Plugin presence is implicit — if you're running this skill, the plugin is installed.)

- **`needs-setup`** — no state dir / no `.env.local`. Run `setup.sh`, then prompt for the OpenRouter key.
- **`needs-key`** — `.env.local` present but the API key is still the placeholder. Pipe it in via `echo "<key>" | bash <SKILL_DIR>/scripts/set-key.sh` (never the Edit/Write tools, never echo the key back).
- **`ready`** — go straight to **Use** for the user's actual request.

---

## Help mode — "what can sidecar do?", "sidecar help"

When the request is discovery rather than execution, don't run scripts up front — give this capability tour in your own words, one example phrase per feature. This table is the canonical tour; the setup wrap-up (step 6) and the `/sidecar:help` command both reference it, so it lives only here.

| Capability | The user says | What happens |
|---|---|---|
| Second opinion | "ask Gemini to review this plan" | The prompt runs on another model as a full Claude subagent — it can read files and this conversation, not just chat |
| Compare models | "ask Gemini AND GPT how to structure this" | One prompt forks to several models in parallel; answers come back labeled, with disagreements surfaced |
| Follow-ups | "ask Gemini what it meant by X" | Continues the previous sidecar conversation with its context intact |
| Structured fold | "…and fold the answer back" | The answer returns as answer / evidence / confidence / sources, ready to integrate into ongoing work |
| Let it write code | "have DeepSeek fix this and run the tests" | Sidecars are read-only by default; asking for fixes/execution enables full tools |
| Models & cost | "switch sidecar to grok", "what has sidecar cost me" | Change the default model, browse the live catalog with $/M pricing, see per-ask history + remaining credit |
| Usage dashboard | "show my OpenRouter usage", "what's my balance" | Pulls live account balance + today/week/month spend from OpenRouter and renders it as an on-demand chart |

Close the tour with Sidecar's current state: run the Step 0 config check (plus `status.sh` if ready), then either offer setup or suggest a first ask tailored to what the user is currently working on.

---

## Setup ("install sidecar", "set up sidecar")

### Happy path (scan this first)

The full happy path. Numbers tie to the detailed steps below — when in doubt, just run these in order:

```bash
# (1) Run setup: creates state dir + .env.local from template, probes connectivity
bash <SKILL_DIR>/scripts/setup.sh

# (2) COWORK ONLY: if setup reported openrouter.ai NOT reachable, send the
#     user to Cowork Settings ▸ Capabilities ▸ Allowed domains, then rerun (1).
#     (Claude Code has no allow-list — a failed probe there is real network trouble.)

# (3) Render the elicitation form (mcp__visualize__show_widget). Collect:
#     - api_key:        sk-or-...
#     - default_model:  one of the six slugs in the cards table below
#     CLAUDE CODE: no visualize tools — AskUserQuestion for the model pick
#     (max 4 options: use the first four cards, name the other two in the
#     question text), and ask the user to paste the key in chat.

# (4) Write the key (NEVER use Edit/Write on .env.local — see virtiofs note):
echo "<api-key-from-form>" | bash <SKILL_DIR>/scripts/set-key.sh

# (5) Set the model AND verify in one bash call (chain with &&):
bash <SKILL_DIR>/scripts/set-model.sh <slug-from-form> && \
  bash <SKILL_DIR>/scripts/test.sh

# (6) On 8/8 PASS: give the quick capability tour (see step 6 below — no scripts to run)
```

**Batch where you can.** Any two scripts with a clear linear dependency belong in the same bash call — `set-model.sh && test.sh`, `setup.sh && cat <state>/.env.local`, etc. Each separate bash invocation is a tool round-trip; chains save them.

**Task tracking on this short flow.** The setup happy path is six steps and pure linear scripting. If you're going to track with `TaskCreate`, create all six tasks at the start in one batch — don't add tracking mid-flow, you'll spend more calls on bookkeeping than on the work. For most setups, skipping task tracking entirely is fine.

### Detailed steps

1. **Run setup.**
   ```bash
   bash <SKILL_DIR>/scripts/setup.sh
   ```
   Idempotent. Verifies prereqs, ensures the vendored proxy bundle is intact, creates `<connected-folder>/sidecar-state/` if missing, seeds `.env.local` from template, runs a writability probe on the state dir, and probes outbound connectivity to `openrouter.ai`.

2. **Confirm the openrouter.ai allow-list (Cowork only).** Cowork sandboxes restrict outbound traffic to allow-listed domains. If `setup.sh` reported `openrouter.ai NOT reachable`, tell the user to:

   > Open Cowork Settings ▸ Capabilities ▸ Allowed domains and add `openrouter.ai` (or temporarily flip "Allow all domains" for testing). Then rerun `setup.sh` to confirm the probe passes.

   Without this step, every Sidecar request will fail with DNS errors regardless of the API key.

3. **Collect the API key + default model via an interactive form. Use the EXACT cards specified below — do not improvise.**

   ⚠️ **Sidecar exists to get adversarial, second-opinion reviews from models *other than* the parent Claude. Do NOT offer an Anthropic/Claude model as a setup option, and never default to one — an Anthropic default defeats the entire purpose.** The user can still explicitly switch to Claude later (see "Switch default model"); just don't surface it during setup.

   ⚠️ **Do NOT use model names you "know" from training data.** Your training data is older than the current OpenRouter catalog. **Specifically, do NOT show:** GPT-4, GPT-4o, GPT-4-turbo, Gemini 2.5 Pro, Gemini 1.5 Pro, or any other model not in the table below. Use the six slugs verbatim. If a slug appears unfamiliar to you, that's expected — it's newer than your training data.

   **Steps:**

   1. Call `mcp__visualize__read_me` with `modules: ["elicitation"]` to load the form-styling guide.
   2. Call `mcp__visualize__show_widget` with an elicitation form that has:
      - A `<textarea>` (monospace, `data-name="api_key"`) for the OpenRouter API key (pointing the user at https://openrouter.ai/keys).
      - A card-style `.elicit-pills` group (`data-name="default_model"`, `data-multi="false"`) with **EXACTLY THESE SIX CARDS, IN ORDER, AND NO OTHERS**. Include the price in each card's description — cost is part of the decision (prices are $/M tokens in/out, June 2026 snapshot):

        | Card label | One-line description | `data-value` slug (use verbatim) |
        |---|---|---|
        | Gemini 3.5 Flash | Newest Gemini — fast, balanced, good value ($1.50 / $9) | `google/gemini-3.5-flash` |
        | GPT-5.4 | Near-flagship OpenAI at half the price of 5.5 ($2.50 / $15) | `openai/gpt-5.4` |
        | DeepSeek V4 Flash | Budget pick — solid code & reasoning ($0.10 / $0.20) | `deepseek/deepseek-v4-flash` |
        | Grok 4.3 | xAI's flagship — independent vendor, cheap output ($1.25 / $2.50) | `x-ai/grok-4.3` |
        | Gemini 3.1 Pro | Strongest Gemini reasoning, long context ($2 / $12) | `google/gemini-3.1-pro-preview` |
        | GPT-5.5 | OpenAI's flagship — premium price ($5 / $30) | `openai/gpt-5.5` |

   3. Parse the submitted form. Then:
      - Write the key via `bash <SKILL_DIR>/scripts/set-key.sh` (pipe the key through stdin: `echo "<key>" | bash <SKILL_DIR>/scripts/set-key.sh`). **Never** use the Edit/Write tools on `.env.local` — virtiofs/OneDrive backed mounts (Windows hosts) silently drop those edits. Always inject via bash redirect.
      - Set the model with `bash <SKILL_DIR>/scripts/set-model.sh <slug>` (validates against the live catalog).

4. **Only fall back from the six slugs above if `set-model.sh` actually rejects them as 404.** Don't pre-emptively "verify" against your own model knowledge — those six slugs are validated and current. The check that matters is `set-model.sh` calling OpenRouter's catalog. If (and only if) it returns "Unknown slug", run `bash <SKILL_DIR>/scripts/list-models.sh <vendor>` and pick the most recent match — and tell the user which slug you substituted and why.

5. **Verify.**
   ```bash
   bash <SKILL_DIR>/scripts/test.sh
   ```
   8 checks. 8/8 PASS means everything works.

6. **Wrap up with the quick tour.** A setup that ends at "8/8 PASS" leaves the user not knowing what to ask for — most installed because they heard "ask Gemini things" and will never discover compare, follow-ups, or fold on their own. After a passing test:
   - Give a compressed version of the **Help mode** tour — one line per capability, headline phrases only, NOT the full table. Keep the whole wrap-up to ~6 lines so the "it works" signal isn't buried under feature documentation.
   - Offer a first ask tailored to what the user is currently working on ("want to try it? e.g. *ask Gemini for a second opinion on <their current task>*").
   - Mention they can say **"sidecar help"** (or run `/sidecar:help`) anytime for the full rundown.

---

## Use — handling an "ask <vendor> to ..." request

### 🚫 Do NOT curl the proxy directly to answer a prompt

The proxy is the **transport**, not the **agent**. It only translates Anthropic ↔ OpenAI format and forwards to OpenRouter. A direct `curl http://127.0.0.1:3000/v1/messages -d {...}` returns a single shot of model output with **no Read, no Grep, no Bash, no transcript access, no tool-use loop** — none of the things that make a Claude CLI subagent actually useful.

**Always go through `ask.sh`.** It spawns a fresh `claude -p` subprocess (sub-Claude) with `--add-dir` pointing at the parent transcript and `--append-system-prompt` instructing sub-Claude how to use it. Sub-Claude then reasons, calls tools, grep-walks the transcript on demand, and returns a real answer. Skipping that and curling the proxy is functionally `curl openrouter.ai` with extra steps — you've defeated the entire purpose of the harness.

| Operation | Right tool |
|---|---|
| Answering a user's "ask <vendor> to ..." prompt | `ask.sh` (always — spawns sub-Claude) |
| Switching default model | `set-model.sh` |
| Health check / debugging the proxy | curl is fine here (test.sh does this) |
| Listing the catalog | `list-models.sh` |
| Verifying setup | `test.sh` |

If you find yourself reaching for `curl http://127.0.0.1:3000/v1/messages` to satisfy a user-facing request, stop — use `ask.sh` instead.

### 1. Resolve the vendor → model

The vendor → slug map lives in `<state>/defaults.env` (seeded by `setup.sh`, per-user, refreshable — it does NOT live in this document, because the catalog turns over). `ask.sh --model` resolves bare vendor words (**gemini, gpt, deepseek, grok, llama**) through it automatically, so for vendor-level requests there is nothing to resolve yourself.

If a slug has gone stale (upstream says "not a valid model ID"), refresh the alias and retry:

```bash
bash <SKILL_DIR>/scripts/refresh-defaults.sh                  # current map + newest candidates per vendor
bash <SKILL_DIR>/scripts/refresh-defaults.sh gemini <new-slug>  # validate + remap
```

Anthropic/Claude is deliberately not aliased — Sidecar is for second opinions from a *different* model than the parent Claude. If the user *explicitly* asks for Claude anyway, honor it with a full slug (`ask.sh --model anthropic/<slug>`; find it via `list-models.sh claude`).

If the user names a *specific* model ("ask GPT-5 Codex"), search the catalog and pass the full slug:
```bash
bash <SKILL_DIR>/scripts/list-models.sh gpt-5
```

### 2. Per-call override vs default switch

`ask.sh --model <slug-or-vendor>` overrides per call without touching any state — use it for every "ask <vendor> ..." request. Only run `set-model.sh <slug>` when the user wants to *change their default* ("switch sidecar to grok"). Concurrent asks to different models are safe: each gets its own proxy on its own port.

### 3. Run the prompt — use `scripts/ask.sh`

`ask.sh` is the canonical entry point. It boots a proxy on a free port, locates the parent Cowork transcript, spawns sub-Claude with `--add-dir` access to that transcript plus a system-prompt hint, runs the prompt, then cleans up. Sub-Claude self-decides whether to consult the transcript based on the question.

```bash
bash <SKILL_DIR>/scripts/ask.sh --model gemini "<the user's prompt verbatim>"
```

Or via stdin (better for prompts with quotes/special chars):

```bash
echo "<the user's prompt verbatim>" | bash <SKILL_DIR>/scripts/ask.sh --model gemini
```

Other flags (combine freely):

- `--fold` — sub-Claude ends with a structured fold block (answer / key evidence / confidence / sources consulted). Use when you'll integrate the answer into further work rather than just relaying it.
- `--full-tools` — **sub-Claude is read-only (Read/Grep/Glob) by default.** Add this when the ask requires running code or writing files ("have DeepSeek fix this", "run the tests"); leave it off for opinions, reviews, and summaries.
- `--add-dir <path>` — extra readable directory (e.g. the user's project folder for "have GPT review this repo").
- `--continue` — resume the previous sidecar conversation (see step 5).

**Output contract:** the first stdout line is always `[sidecar: <slug>]`, written by ask.sh from config — the authoritative routing record. Relay it (or fold it into your attribution); don't hand-write a model preface, and don't trust the model's own claims about its identity.

### 4. About the parent-transcript access

`ask.sh` always passes the parent's Cowork conversation jsonl as a readable directory (`--add-dir`) and tells sub-Claude *"only consult it if the prompt requires context."* Cost: ~one paragraph in sub-Claude's system prompt. Benefit: questions like "summarize what we just discussed" actually work without you (parent Claude) writing context manually.

If the user's prompt is clearly self-contained ("what is 13 × 17"), sub-Claude will ignore the transcript. If it's context-dependent, sub-Claude will Grep it and Read just the matching range — never the whole file.

### 5. Follow-ups — sessions and `--continue`

Each successful ask records its session (id, model, cwd) in the sandbox. When the user follows up on a previous sidecar answer ("ask Gemini what it meant by X"):

```bash
bash <SKILL_DIR>/scripts/ask.sh --continue "what did you mean by X?"
```

Sub-Claude resumes with its prior context intact — same model unless `--model` is also given. Sessions survive between bash calls but **not across Cowork sessions**; if `--continue` reports no prior session, re-ask with the needed context inline. For a multi-step prompt within one ask, just put both steps in the prompt — sub-Claude handles them in sequence.

### 6. Compare models in parallel ("ask Gemini AND GPT ...")

```bash
bash <SKILL_DIR>/scripts/compare.sh "<prompt>" gemini gpt deepseek
```

Each fork is a full ask.sh subagent running concurrently on its own proxy/port; output is one labeled section per model (failed forks show their error tail inline without sinking the rest). **Launch compare.sh with `run_in_background: true` and read the result via TaskOutput** — N parallel reasoning chains will exceed the bash tool's 45s ceiling. The fold is YOUR job afterwards: synthesize the sections, surface where the models disagree, and attribute claims to the models that made them.

---

## Troubleshooting timeouts and hangs

**There are two timeout layers in play.** Knowing which one fired tells you what to fix.

| Layer | Default | Where it lives | What to do if it fires |
|---|---|---|---|
| `ask.sh` `MAX_RUN_SECONDS` | 180s | inside the script | Bump it: `MAX_RUN_SECONDS=300 bash <SKILL_DIR>/scripts/ask.sh "..."` |
| Cowork bash tool ceiling | 45s | the tool itself | **Launch the bash call with `run_in_background: true` and read the result via TaskOutput when it completes** — this dodges the ceiling entirely and is the default move for any ask that might run long (always for compare.sh). Fallbacks: split the work into shorter prompts, or run from a real terminal. |
| Upstream fetch (OpenRouter) | 120s | `proxy/anthropic-proxy-patched.mjs` | A hung Gemini/OpenAI request can't take longer than 120s before the proxy gives up. Logged in `$HOME/sidecar-ask.<pid>.log` (newest: `ls -t $HOME/sidecar-ask.*.log \| head -1`). |

**Read the failure message ask.sh prints.** Exit codes are diagnostic:
- `124` — hit `MAX_RUN_SECONDS`. Bump it.
- `137` — SIGKILL, almost always the bash tool's 45s ceiling.
- anything else — sub-Claude or upstream returned an error; check the proxy-log tail and stderr tail that ask.sh dumps automatically.

**Get progress visibility during long calls.** Set `SIDECAR_VERBOSE=1` to mirror sub-Claude's stderr live as the call runs:

```bash
SIDECAR_VERBOSE=1 MAX_RUN_SECONDS=300 bash <SKILL_DIR>/scripts/ask.sh "<long prompt>"
```

You'll see tool-use events, transcript-grep activity, and any upstream errors as they happen rather than only at the end. Note: the bash tool still buffers output to its caller until the command completes — `SIDECAR_VERBOSE` is most useful when running ask.sh from a terminal, or when redirecting to a tail-able file.

**Common failure shapes and fixes:**

| Symptom | Likely cause | Fix |
|---|---|---|
| Empty / one-sentence response, exit 0 | Thinking model (Gemini 3.x Pro, GPT-5.5 reasoning) burned most of `max_tokens` on internal CoT before visible text. Made worse if `SIDECAR_STREAMING=false`, which drops the model's `reasoning` field entirely. | Two-part fix: (a) keep `SIDECAR_STREAMING=true` (default since 2026-05-06 — set explicitly in `.env.local` if you upgraded an old install); (b) bump max_tokens to ≥3000 for Gemini 3.x Pro, ≥1500 for other thinking models. The 200 floor in `test.sh` only confirms the proxy works at all; real prompts need much more headroom. |
| `EAI_AGAIN getaddrinfo` in proxy log | DNS / outbound network blocked | Cowork: add `openrouter.ai` to Settings ▸ Capabilities ▸ Allowed domains. Claude Code: check the host's network/VPN |
| `No allowed providers` upstream error | OpenRouter account doesn't have the provider for that model | Enable provider at https://openrouter.ai/settings/preferences, or pick a different slug |
| `is not a valid model ID` | Stale slug | Run `list-models.sh <vendor>` and use a current one |
| Hangs forever, no output | Proxy crashed or upstream hung | ask.sh auto-restarts a dead proxy and retries once; the 120s upstream timeout fires on hangs. Check `tail -20 $(ls -t $HOME/sidecar-ask.*.log \| head -1)` for the actual error |
| Exit 137 (SIGKILL) | Cowork bash tool ceiling | Relaunch with `run_in_background: true` (read via TaskOutput), or chunk the work |
| "tool not allowed" / sub-Claude can't run code | Read-only default | Rerun with `--full-tools` (or `SIDECAR_TOOLS=full`) |
| "maximum context length is N tokens... of tool input" | Host has many MCP servers — their tool schemas alone can be 50k+ tokens, busting small-context models (mostly a Claude Code issue; Cowork sandboxes carry fewer tools) | Pick a bigger-context model (≥400k: `openai/gpt-5-nano`, `openai/gpt-4.1-nano`, Gemini) |

**Don't mistake a slow call for a stuck one.** Reasoning + tool-use chains routinely take 60–120s. Wait for `MAX_RUN_SECONDS` before declaring it stuck.

---

## Other workflows

### Switch default model ("switch sidecar to grok")

```bash
bash <SKILL_DIR>/scripts/list-models.sh grok
bash <SKILL_DIR>/scripts/set-model.sh x-ai/grok-4.3
```

(For a one-off model choice, prefer `ask.sh --model` — it doesn't touch the default.)

### Refresh a stale vendor alias ("gemini slug 404s")

```bash
bash <SKILL_DIR>/scripts/refresh-defaults.sh                  # view map + newest candidates
bash <SKILL_DIR>/scripts/refresh-defaults.sh gemini <slug>    # validate + remap
```

### Test ("test sidecar")

```bash
bash <SKILL_DIR>/scripts/test.sh
```

### Status / spend ("what's sidecar configured for", "what has sidecar cost me")

```bash
bash <SKILL_DIR>/scripts/status.sh
```

Shows config, proxy state, the last 5 asks (time, model, duration, exit code, tokens — from `<state>/history.log`), and remaining OpenRouter credit. `list-models.sh` shows $/M token pricing per model for cost-informed model picks. For account-wide usage analytics (not just this project's asks), see **Usage dashboard** below.

### Usage dashboard ("what's my OpenRouter balance", "how am I using my credits", "visualize my spend")

```bash
bash <SKILL_DIR>/scripts/usage.sh --json
```

All data comes live from the OpenRouter API using the user's regular key — account-wide and cross-project, deliberately NOT the local `history.log` (which only sees asks made from one state dir). The JSON has two sections:

- `credits` — balance + all-time purchased/used.
- `spend` — today / this week / this month, plus the key's spend `limit` (null = unlimited).

**Per-model breakdowns are deliberately unsupported — never suggest a workaround.** OpenRouter only exposes per-model analytics to "management" keys, which can create and delete API keys; that is far too much privilege to ask a user to paste into a tool, so Sidecar will not request or store one. If the user asks which models are consuming their credit, say exactly that, then offer the closest safe views: the OpenRouter dashboard at https://openrouter.ai/activity (their browser, their session), `status.sh` (recent asks with models + tokens, this project only), and `list-models.sh` $/M pricing.

**Visualize, don't dump JSON.** This is the payoff of the feature — turn the data into a chart:

- **Cowork**: call `mcp__visualize__read_me` with `modules: ["data_viz", "chart"]`, then `mcp__visualize__show_widget`. Good defaults: a headline balance figure with a used-vs-remaining gauge or donut from `credits`, next to a bar group of the `spend` windows (today / week / month). If a spend limit is set, show balance against it.
- **Claude Code**: no visualize tools — run `usage.sh` without `--json` for the formatted summary, or present a compact markdown table from the JSON.
- Never include the key in chart code, labels, or any output.

---

## Important behavior notes

- **Proxy is transport, not agent.** Curling `/v1/messages` directly returns one model shot with no tool use, no transcript context, no reasoning loop. To answer a user prompt, always use `ask.sh` (which spawns sub-Claude). Curl is acceptable only for diagnostics or `test.sh`-style probes.
- **Plugin is read-only.** State (.env.local) lives in the user's connected folder under `sidecar-state/` (or legacy `.sidecar/`), not inside the plugin. The plugin install caches a vendored proxy; it doesn't mutate at runtime.
- **Model identity is unreliable.** Models often hallucinate Claude/GPT regardless of what's actually configured. Authoritative source: the `[sidecar: <slug>]` first line of ask.sh's stdout (printed from config, not the model), or the proxy log.
- **Sub-Claude is read-only by default** (`Read,Grep,Glob`; Bash/Edit/Write/WebFetch disallowed). A third-party model is driving it — write/execute capability is opt-in via `--full-tools` or `SIDECAR_TOOLS=full`.
- **The Claude CLI's own `--model` flag is cosmetic** when going through Sidecar — the proxy substitutes upstream using `COMPLETION_MODEL`/`REASONING_MODEL` (or ask.sh's per-call `SIDECAR_*_OVERRIDE`s).
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
- **Occasional crashes.** `anthropic-proxy` sometimes blows up on a partial JSON chunk from OpenRouter. ask.sh detects a dead proxy after a failed call and auto-restarts + retries once; if crashes become a regular nuisance, pin the version in the vendored package.
- **Sessions are sandbox-scoped.** The `--continue` map lives at `$HOME/.sidecar-sessions` inside the sandbox (deliberately NOT the mounted state dir — the session JSONLs it points to die with the Cowork session, so the map must too).
