# PocketServe

An iOS app that turns an iPhone into a **local (LAN) OpenAI-compatible inference server**. It serves Apple's on-device foundation model (`apple-afm`) and downloadable **MLX** models over plain HTTP, so any OpenAI-compatible client on the same network can call them.

> **Public-launch note:** the iPhone app UI is currently **Polish-only**. Before a public release the whole app must be localized to **English** (and ideally made multi-language). See [ROADMAP.md § Phase 4 — Public launch / i18n](docs/ROADMAP.md).

## Why
Run a private, offline-first AI endpoint from a phone you already carry — no cloud, no API keys — and consume it from a desktop "Companion" client (Phase 3) over Wi‑Fi.

## Status (as of 2026-09-20)
- **Phase 1 — Apple AFM endpoint:** merged, working on device.
- **Phase 2 — MLX engine + HF model management + iOS UI:** implemented, device smoke passed; **pending final fixes + merge** (`feat/pocketserve-phase2`, 19 commits). See [HANDOFF-PHASE2-CLOSEOUT.md](docs/HANDOFF-PHASE2-CLOSEOUT.md).
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

## Repositories / model IDs
- `apple-afm` — Apple FoundationModels (default, no download).
- `mlx:<repo>` — MLX quantized models from `mlx-community` (downloaded via Hugging Face).
- Presets offered in the iOS "Models" picker (verified live 2026-09-20): Qwen3 0.6B/1.7B 4-bit, Gemma 3n E2B/E4B 4-bit.

## Quickstart (dev)
```bash
# Tests (both packages are macOS-buildable, no simulator needed)
PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit      # 22/22
PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat   # 50/50

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
