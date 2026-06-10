# Sidecar

Run any OpenRouter-hosted LLM as a Claude CLI subagent — in Claude Cowork or Claude Code, through a thin format-translation proxy.

Sidecar gives you a `claude -p "..."` invocation that quietly routes to whichever upstream model you configure (Gemini, DeepSeek, Claude, GPT, anything OpenRouter serves). The Claude CLI thinks it's talking to Anthropic; the proxy translates to OpenAI chat-completions on the way out and back.

## Why this exists

Claude Cowork is Claude end to end. There's no built-in way to hand a question to Gemini, GPT, or DeepSeek mid-session — no "second opinion" button, no multi-model fan-out. Sidecar adds that: fork a prompt to another model (or several in parallel), fold the answers back into your main Claude context (the Fork & Fold pattern). Subagents can keep their own multi-turn sessions, run read-only by default, and report what each call cost.

The design follows directly from how Cowork works under the hood:

- **The Claude CLI is already in the sandbox.** Every Cowork session runs in a Linux VM that ships with the `claude` CLI — a full agent harness with tools, file access, and an agentic loop. That's a much better subagent runtime than a bare API call. But it speaks only the Anthropic Messages API.
- **OpenRouter's Anthropic-compat endpoint isn't compatible enough.** Pointing `claude` straight at OpenRouter trips over SSE streaming quirks and format mismatches. So Sidecar runs a local proxy (`127.0.0.1:3000`) that accepts Anthropic `/v1/messages` requests and translates them to OpenAI `/v1/chat/completions` for OpenRouter.
- **Sessions are ephemeral and isolated.** Each Cowork chat gets a fresh VM — no persistent processes, no preinstalled git, no carried-over npm state, and mid-session `npm install` is slow and flaky. So the proxy ships **vendored**: all dependencies are pre-bundled into a single `bundle.cjs` inside the plugin. Nothing to install at runtime; the proxy spawns per bash call, serves the request, and exits.
- **Plugins persist; sessions don't.** Distributing this as a Cowork plugin means it's available in every session automatically. The only per-user state is `.env.local` (your OpenRouter key + default model), which lives in your mounted folder so it survives across sessions.

The same constraints explain [SETUP-GIT.md](SETUP-GIT.md): the Cowork sandbox doesn't include git, so repo operations happen from a regular terminal on the host.

## What's in here

```
sidecar-plugin/
├── .claude-plugin/
│   ├── plugin.json            # plugin manifest
│   └── marketplace.json       # marketplace listing for install-from-repo
├── build.sh                   # packages everything into ../sidecar.plugin
├── SETUP-GIT.md               # why git runs on the host, not in Cowork
├── skills/sidecar/
│   ├── SKILL.md               # skill definition (loaded by Cowork as `sidecar`)
│   ├── .env.local.template    # template for per-user config
│   ├── defaults.env.template  # vendor → model alias map (seeded into state dir)
│   ├── proxy/
│   │   ├── bundle.cjs         # vendored anthropic-proxy + deps (esbuild, single file)
│   │   ├── wrapper.mjs        # entry point; honors HTTP(S)_PROXY in sandboxes
│   │   ├── anthropic-proxy-patched.mjs
│   │   └── package.json / package-lock.json
│   └── scripts/
│       ├── setup.sh           # idempotent first-run setup
│       ├── set-key.sh         # store your OpenRouter API key
│       ├── start.sh / stop.sh / status.sh
│       ├── test.sh            # full end-to-end verification
│       ├── ask.sh             # run a prompt as a subagent (--model/--continue/--fold/...)
│       ├── compare.sh         # fork one prompt to N models in parallel
│       ├── list-models.sh     # query the live OpenRouter catalog (with $/M pricing)
│       ├── set-model.sh       # change the persistent default model
│       ├── refresh-defaults.sh# view/update the vendor → model alias map
│       ├── find-transcript.sh # locate parent-conversation transcript for context self-pull
│       ├── _locate.sh         # state-dir discovery helper
│       └── _runtime.sh        # shared helpers (port probing, proxy boot, alias resolution)
└── tests/                     # dev-only, never shipped in the .plugin
    ├── integration/           # bash tests/run-integration.sh — no network, no key
    └── live/matrix.sh         # real-OpenRouter 3-provider matrix (run before release)
```

`node_modules/` exists only at build time and is gitignored — `build.sh` regenerates it from the lockfile and bundles it into `bundle.cjs`.

## Install

### From the marketplace (recommended)

This repo doubles as a Claude Code plugin marketplace, so it can be installed remotely into Claude Code or Cowork:

```
/plugin marketplace add jrenaldi79/sidecar-plugin
/plugin install sidecar@sidecar-marketplace
```

Or tell Claude in a Cowork chat:

> add the plugin marketplace at https://github.com/jrenaldi79/sidecar-plugin and install the sidecar plugin

After install, run the skill's setup once to enter your OpenRouter API key (get one at https://openrouter.ai/keys):

> set up sidecar

### Manual (build the .plugin file)

```bash
bash build.sh
# outputs sidecar.plugin one directory up
```

Import `sidecar.plugin` into Cowork (Settings → Plugins), then say "set up sidecar" in a chat. Claude runs `setup.sh`, asks for your OpenRouter key, helps you pick a default model, and verifies end to end.

## Usage

In a Cowork chat:

> ask Gemini to review this plan
> what does ChatGPT think about this tradeoff?
> compare Gemini and GPT on this question
> ask Gemini a follow-up about that
> have DeepSeek summarize this file
> switch sidecar to grok
> what sidecar models are available, and what do they cost?

Any phrasing that routes a prompt to a non-default model triggers the skill. See [skills/sidecar/SKILL.md](skills/sidecar/SKILL.md) for the full invocation contract, model-switching flow, and troubleshooting.

From a repo checkout you can also drive the scripts directly:

```bash
bash skills/sidecar/scripts/ask.sh --model gemini "review this plan"   # one fork
bash skills/sidecar/scripts/ask.sh --continue "expand on point 2"      # follow-up, same session
bash skills/sidecar/scripts/compare.sh "is this API design sound?" gemini gpt deepseek
bash skills/sidecar/scripts/list-models.sh deepseek      # browse the catalog ($/M pricing included)
bash skills/sidecar/scripts/status.sh                    # config + recent asks + remaining credit
bash skills/sidecar/scripts/test.sh                      # end-to-end check
bash tests/run-integration.sh                            # Tier 1: mock-based, free
bash tests/live/matrix.sh                                # Tier 2: live, needs key
```

### Fork & Fold features

- **Per-call model override** — `ask.sh --model <slug-or-vendor>` routes one prompt without touching your default. Bare vendor words (`gemini`, `gpt`, `deepseek`, `grok`, `llama`) resolve through a per-user alias map (`sidecar-state/defaults.env`); refresh stale slugs with `refresh-defaults.sh`.
- **Parallel compare** — `compare.sh "<prompt>" <model> <model> ...` runs each fork concurrently on its own proxy/port and prints labeled sections per model.
- **Sessions** — each ask records its session; `ask.sh --continue` resumes the conversation with the same model (within one Cowork session).
- **Fold contract** — `ask.sh --fold` makes the subagent end with a structured block (answer / evidence / confidence / sources), and every ask's first output line is `[sidecar: <slug>]` — the authoritative routing record.
- **Read-only by default** — subagents get `Read/Grep/Glob` only; pass `--full-tools` when the task genuinely needs to run code or write files.
- **Cost visibility** — `history.log` records every ask (model, duration, tokens); `status.sh` shows the last five plus your remaining OpenRouter credit; `list-models.sh` lists $/M token pricing.

## Architecture

```
   claude -p "..."
        │
        │  (Anthropic API format, /v1/messages)
        ▼
   ┌────────────────────────┐
   │ Sidecar proxy          │  127.0.0.1:<probed port>
   │ (vendored bundle.cjs)  │  spawns per call, exits after;
   └────────────────────────┘  parallel asks each get their own
        │
        │  (OpenAI chat-completions format, /v1/chat/completions)
        ▼
   ┌────────────────────────┐
   │ OpenRouter             │
   │ openrouter.ai/api/v1   │
   └────────────────────────┘
        │
        ▼
   any OpenRouter model
   (Gemini, DeepSeek, Claude, GPT, …)
```

The translation layer is a patched [anthropic-proxy](https://github.com/maxnowack/anthropic-proxy) (MIT, Max Nowack), bundled with its dependencies via esbuild.

## Things to know

- **Per-user state is auto-discovered.** In Cowork: a `sidecar-state/` (or legacy `.sidecar/`) dir in whichever folder is connected. In Claude Code on a host: `~/.sidecar-state/`. `SIDECAR_STATE_DIR` overrides both. `.env.local` holds your key — never share or commit it.
- **The proxy process is per-bash-call.** Inside the sandbox, start it and use it within the same bash invocation; it doesn't outlive the call.
- **Model identity is unreliable.** Ask a sidecar model "which model are you?" and it will often hallucinate Claude/GPT regardless of what's actually upstream. The authoritative source is the `[sidecar: <slug>]` line ask.sh prints first (taken from config, not from the model), or the proxy log.
- **Subagents are read-only by default.** A third-party model drives the Claude CLI subagent, so Bash/Edit/Write are opt-in (`--full-tools`). Good default for reviews and second opinions; lift it deliberately when the task needs execution.
- **Provider allowlists.** Some OpenRouter models are only served by specific providers (e.g. DeepSeek R1 needs `novita` or `azure`). On a 404 with "No allowed providers", flip providers on at https://openrouter.ai/settings/preferences.

## Operating systems

The Cowork sandbox is a Linux VM regardless of host OS, so the bash scripts and the bundled Node proxy run identically from Cowork on Mac, Windows, and Linux hosts. Only the host-side path representation differs (`/Users/...` on Mac, `C:\Users\...` on Windows) — inside the sandbox both map to `/sessions/<id>/mnt/...`, and the scripts handle that (see the path-translation note in SKILL.md).

If you want to run the proxy *outside* Cowork (e.g. as a long-lived service on your machine):

| Host | What to do |
|---|---|
| macOS | `bash skills/sidecar/scripts/start.sh` — works directly. To survive reboots, wrap in a launchd plist. |
| Linux | Same as macOS. To survive reboots, a systemd user unit. |
| Windows | Use **WSL2** (Ubuntu) and run the same bash scripts. Native PowerShell/cmd would need ports of the scripts. Git Bash works for the basics but lacks `/dev/tcp/` and a few other features the scripts use. |

For most users the in-Cowork path is enough — the proxy spawns per-bash-call within a session, runs the prompt, and exits.

## Distributing to teammates

The easiest path is the marketplace install above — point teammates at:

```
/plugin marketplace add jrenaldi79/sidecar-plugin
/plugin install sidecar@sidecar-marketplace
```

Alternatively, send them the built `sidecar.plugin` file (or have them clone this repo and run `build.sh`). They import it into Cowork, say "set up sidecar", and go through the same key + model flow with their own OpenRouter account.

`.env.local` is per-user — never share yours.

## License

The proxy itself is MIT-licensed (Max Nowack). This skill bundle is yours to modify and distribute.
