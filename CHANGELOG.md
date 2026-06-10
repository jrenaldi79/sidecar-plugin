# Changelog

## 0.5.0 — 2026-06-10 "Reasoning Effort"

Users can now control reasoning effort — the biggest per-call cost lever
after model choice (reasoning tokens bill at the OUTPUT rate).

### Added
- **Proxy PATCH E1**: when `SIDECAR_REASONING_EFFORT` is `low`/`medium`/`high`,
  the proxy forwards OpenRouter's vendor-normalized `reasoning: { effort }`
  param. Unset or invalid = omitted = each provider's default (the previous
  behavior, now locked by regression tests). Both bundles rebuilt.
- **`set-effort.sh`** — persistent default in `.env.local`
  (`low|medium|high|default`), same virtiofs-safe write pattern as set-key.sh.
- **`ask.sh --effort low|medium|high`** — per-call override via
  `SIDECAR_EFFORT_OVERRIDE` (applied by start.sh after `.env.local`, like the
  model overrides). Also works for compare.sh via the exported env var.
- **Setup asks for effort**: the elicitation form gains a reasoning-effort
  pick (provider default preselected); SKILL.md guides per-task choice
  (low for summaries, high for deep adversarial reviews).

### Changed
- Setup model cards: 6 → 8 — added `deepseek/deepseek-v4-pro` ($0.43/$0.87)
  and `moonshotai/kimi-k2.6` ($0.68/$3.41), both live-catalog verified.

## 0.4.1 — 2026-06-10 "Cost-Aware Setup"

Setup now shows prices and leads with cost-effective picks (all pricing
verified against the live OpenRouter catalog, June 2026).

### Changed
- **Setup model cards: 4 → 6, each with $/M pricing.** Added
  `google/gemini-3.5-flash` ($1.50/$9 — newest Gemini, cheaper than 3.1 Pro)
  and `openai/gpt-5.4` ($2.50/$15 — half the price of GPT-5.5). Cards are
  ordered value-first; GPT-5.5 ($5/$30) and Gemini 3.1 Pro stay available
  but are labeled premium. Claude Code's AskUserQuestion path shows the
  first four and names the premium two in the question text.
- **Cheaper defaults for new installs**: `.env.local` template default is
  now `google/gemini-3.5-flash`; vendor aliases remap `gemini` →
  `gemini-3.5-flash` and `gpt` → `gpt-5.4`. Existing installs keep their
  configured models (state is per-user); remap anytime with
  `refresh-defaults.sh`.

## 0.4.0 — 2026-06-10 "Regular Key Only"

Kills the management-key path introduced in 0.3.0 before anyone adopts it.
An OpenRouter management key can create and delete the account's API keys —
far too much privilege to ask end users to paste into a tool, even for a
read-only chart. The usage dashboard now uses only the regular inference key.

### Removed
- **`set-key.sh --management`** and `OPENROUTER_MANAGEMENT_KEY` (template
  comment included). The flag now fails key validation like any other
  non-key argument.
- **`usage.sh` activity section** — per-model/per-date rollups via
  `/api/v1/activity`. The `--json` contract is now just
  `credits` + `spend`. Local `history.log` aggregation was evaluated and
  rejected as an alternative (per-state-dir, misrepresents cross-project
  usage); a Critical Gotcha in CLAUDE.md guards against reintroducing either.

### Changed
- SKILL.md's Usage dashboard mode instructs Claude to *refuse* per-model
  requests with the reason, and point at the OpenRouter web dashboard
  (user's own browser session), `status.sh`, and `list-models.sh` pricing
  as the safe alternatives.

## 0.3.0 — 2026-06-09 "Usage Dashboard"

Account-wide OpenRouter usage analytics with on-demand visualization.

### Added
- **`usage.sh`** — live OpenRouter usage report: balance + all-time totals
  (`/api/v1/credits`), today/week/month spend (`/api/v1/key`), and — with an
  optional management key — per-model/per-date rollups of the last 30 days
  (`/api/v1/activity`). `--json` emits a machine-readable report
  (`credits` / `spend` / `activity`) that the skill turns into a chart.
  Deliberately API-only: the local `history.log` only sees one project's asks.
- **`set-key.sh --management`** — writes the optional
  `OPENROUTER_MANAGEMENT_KEY` to `.env.local` (same stdin pipe, sk-or-
  validation, and never-echo rules as the API key).
- **SKILL.md Usage dashboard mode** — triggers like "what's my OpenRouter
  balance" / "how am I using my credits"; instructs Claude to render the JSON
  as a visualization (Cowork widget; formatted text in Claude Code) and to
  offer the management-key upgrade when per-model data is locked.

## 0.2.1 — 2026-06-09 "Both Environments"

Sidecar is now first-class in Claude Code on a host, not just Cowork.

- **Host state dir** — `_locate.sh` falls back to `~/.sidecar-state/` when no
  Cowork mount layout (`$HOME/mnt`) exists; Cowork resolution is unchanged
  and always wins inside the sandbox.
- **Host transcript self-pull** — `find-transcript.sh` resolves
  `~/.claude/projects` when the Cowork bind mount is absent, so "ask Gemini
  what we discussed" works in Claude Code too. Also fixes a silent BSD/macOS
  failure (GNU-only `find -printf` replaced with a portable `[ -nt ]` scan).
- **macOS timeout** — ask.sh now falls back to `gtimeout` (brew coreutils)
  before degrading to an unguarded run.
- **Environment-aware docs** — SKILL.md detects Cowork vs Claude Code
  (`[ -d "$HOME/mnt" ]`) and branches: state location, key/model collection
  without the visualize form, allow-list steps marked Cowork-only.
  setup.sh's connectivity guidance is likewise environment-aware.

## 0.2.0 — 2026-06-09 "Fork & Fold"

Completes the Fork & Fold pattern: parallel forks, real folds, and safer
subagents.

### Added
- **`ask.sh --model <slug-or-vendor>`** — per-call model override, no state
  mutation. Bare vendor words (gemini, gpt, deepseek, grok, llama) resolve
  through a per-user alias map.
- **Dynamic ports** — each ask probes for a free port (PID-spread + bind-race
  retry), so concurrent asks to different models run side by side.
- **`compare.sh`** — fork one prompt to N models in parallel; labeled output
  sections per model, failed forks shown inline without sinking the rest.
- **Sessions** — every ask records its `claude -p` session; `ask.sh
  --continue` resumes the previous sidecar conversation (same Cowork session).
- **Fold contract** — `ask.sh --fold` makes the subagent end with a
  structured answer/evidence/confidence/sources block; every ask's first
  stdout line is the authoritative `[sidecar: <slug>]` routing record.
- **Read-only subagents by default** — sub-Claude gets `Read,Grep,Glob` only;
  `--full-tools` (or `SIDECAR_TOOLS=full`) opts into Bash/Edit/Write.
- **`--add-dir <path>`** — extra readable directories for the subagent.
- **Alias map** — `sidecar-state/defaults.env` seeded by setup.sh; new
  `refresh-defaults.sh` validates and remaps stale vendor slugs against the
  live catalog (`SIDECAR_CATALOG_FILE` hook for offline testing).
- **Cost visibility** — `history.log` line per ask (UTC, model, duration,
  exit code, tokens); `status.sh` shows the last 5 asks + remaining
  OpenRouter credit; `list-models.sh` shows $/M input/output pricing.
- **Resilience** — ask.sh restarts a dead proxy and retries once (known
  anthropic-proxy partial-JSON crash); per-PID log/artifact names; graceful
  no-`timeout(1)` degradation on stock macOS.
- `CHANGELOG.md` (this file).

### Changed
- `ask.sh` runs `claude -p --output-format json` internally (session id +
  token usage), with a raw-output fallback if parsing fails.
- SKILL.md: vendor→slug table replaced by the live alias map; 45s-ceiling
  guidance now leads with `run_in_background: true` + TaskOutput.
- `set-model.sh` restart log moved off hardcoded `/tmp`; header points
  one-off routing at `ask.sh --model`.

## 0.1.0 — 2026-05/06

Initial release.

- Vendored `anthropic-proxy` (esbuild single-file bundle — no runtime
  `npm install`; Cowork's validator rejects `@`-scoped paths in zips).
- `ask.sh` subagent harness with parent-transcript self-pull (`--add-dir` +
  system-prompt hint), `setup.sh`/`set-key.sh`/`set-model.sh`/
  `list-models.sh`/`status.sh`/`test.sh`.
- Proxy patches: streaming stability (B1–B4), Anthropic→OpenAI translation
  fixes for tool_calls shape and tool_result adjacency (C1–C3), malformed
  tool-argument tolerance + upstream fetch timeout (P1–P2).
- `SIDECAR_STREAMING` default-on (thinking models drop `reasoning` on the
  non-streaming path).
- Windows/virtiofs/OneDrive write-path hardening (redirect-truncate
  everywhere; no `sed -i`/`mv`; `sidecar-state/` non-dotfile naming).
- Marketplace manifest (`/plugin marketplace add jrenaldi79/sidecar-plugin`).
- Non-Anthropic defaults: Sidecar is for second opinions from models other
  than the parent Claude.
