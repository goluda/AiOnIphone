# PocketServe

An iOS app that turns an iPhone into a **local (LAN) OpenAI-compatible inference server**. It serves Apple's on-device foundation model (`apple-afm`) and downloadable **MLX** models over plain HTTP, so any OpenAI-compatible client on the same network can call them.

> **Public-launch note:** the iPhone app UI is currently **Polish-only**. Before a public release the whole app must be localized to **English** (and ideally made multi-language). See [ROADMAP.md § Phase 4 — Public launch / i18n](docs/ROADMAP.md).

## Why
Run a private, offline-first AI endpoint from a phone you already carry — no cloud, no API keys — and consume it from a desktop "Companion" client (Phase 3) over Wi‑Fi.

## Status (as of 2026-09-20)
- **Phase 1 — Apple AFM endpoint:** merged, working on device.
- **Phase 2 — MLX engine + HF model management + iOS UI:** merged to `main`; device smoke passed; live-discovered defects tracked in [KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md). See [HANDOFF-PHASE2-CLOSEOUT.md](docs/HANDOFF-PHASE2-CLOSEOUT.md).
- **`POST /v1/messages` (Anthropic-shape responses):** merged — see PR #1; device smoke passed 2026-09-20.
- **Phase 2.5 — always-on server (no screen-timeout kill):** not started.
- **Phase 3 — macOS "Companion" client:** not started.
- **Phase 4 — public launch / English localization / App Store prep:** not started.

Full phase plan: [docs/ROADMAP.md](docs/ROADMAP.md)

## Architecture at a glance
```
┌──────────── iPhone (PocketServe) ─────────────┐        LAN        ┌── macOS ──┐
│  SwiftUI UI (Models mgmt) ─┐                    │                    │ Companion  │
│                            ▼                    │                    │  (Phase 3) │
│   ModelsViewModel ──► DownloadCoordinator      │                    └─────┬──────┘
│         │              (ModelKit)               │                          │
│         ▼                                       │   OpenAI-compat HTTP       │
│   ModelStore (persist) ── HFClient/HFDownloader│  ◄───────────────────────┘
│                                                 │   :8080, Bonjour _oai._tcp │
│   HTTPServer (OpenAICompat) ── ServerExtension  │                          │
│        ├── AFMEngine  (apple-afm)               │                          │
│        └── MLXEngine  (mlx:<repo>)            │                          │
└─────────────────────────────────────────────────┘
```
Details & layer rules: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## HTTP endpoints (baseline `http://<iPhone>:8080`)
| Method & path | Response | Notes |
|---|---|---|
| `GET /health` | `{"status":"ok"}` | Liveness probe. |
| `GET /v1/models` | OpenAI `models` list | `apple-afm` + loaded `mlx:<repo>` only (placeholders never listed). |
| `POST /v1/chat/completions` | **OpenAI shape** — JSON (`chat.completion`) or SSE chunks + `data: [DONE]` | OpenAI-compatible clients work out of the box. |
| `POST /v1/messages` | **Anthropic shape** — JSON (`type:"message"`, `content[].text`, `stop_reason:"end_turn"`, `usage.input_tokens/output_tokens`, `id` prefixed `msg_`) or SSE event sequence `message_start` → `content_block_start` → `ping` → `content_block_delta`×N → `content_block_stop` → `message_delta` → `message_stop` (no `[DONE]`) | Request body is OpenAI shape (same as chat completions). Spec: [docs/superpowers/specs/2026-09-20-messages-endpoint-design.md](docs/superpowers/specs/2026-09-20-messages-endpoint-design.md). |
| `GET /x/models` | Model records JSON | Management (PocketServe extension). |
| `GET /x/download/status` | `{state, bytes_done, bytes_total}` | Download progress. |
| `POST /x/download` · `POST /x/models/load` · `POST /x/models/unload` · `DELETE /x/models/<id>` | accepted / status JSON | HF download & lifecycle management. |

Error codes: `429` busy (`server_busy`), `404` unknown model, `409` `mlx:` prefix owned but model not loaded (`model_not_ready`), `400` malformed body, `500` engine failure. On `/v1/messages` errors use the Anthropic envelope (`{"type":"error","error":{"type":...,"message":...}}`).

## Repositories / model IDs
- `apple-afm` — Apple FoundationModels (default, no download).
- `mlx:<repo>` — MLX quantized models from `mlx-community` (downloaded via Hugging Face).
- Presets offered in the iOS "Models" picker (verified live 2026-09-20): Qwen3 0.6B/1.7B 4-bit, Gemma 3n E2B/E4B 4-bit.

## Quickstart (dev)
```bash
# Tests (both packages are macOS-buildable, no simulator needed)
PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit      # 22/22
PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat   # 62/62

# iOS app build
xcodebuild -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 \
  -destination 'generic/platform=iOS Simulator' build
```
> ⚠️ Environment quirk: use `PATH=/usr/bin:$PATH swift …` — the default `swift`/`rg` shims are broken. Details: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md)

On-device run + smoke checklist: [PocketServe/RUN_ON_IPHONE_PHASE2.md](PocketServe/RUN_ON_IPHONE_PHASE2.md)

## Known issues
Live-discovered defects (thinking-token leak, error-envelope leak, screen-timeout server kill) are tracked in [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md).

## Working with agents
Read [AGENTS.md](AGENTS.md) first — layer rules, conventions, and the phase backlog live there.
