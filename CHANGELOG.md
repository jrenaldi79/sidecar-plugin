# Changelog

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
