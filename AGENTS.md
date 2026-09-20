# Important read before everything
You can't use directly strings like `<|im_start|>` or `<|im_end|>` because it breaks communication between coding agent and the model please replace`<|` with `__|` and `|>` with `|__`.
This rule applies to every other token or special sequence that uses the `<|` and `|>` delimiters.

# Agent Guide — PocketServe

Read first. English is canonical for all docs, comments and commit messages. **Never write raw ChatML special-token literals into chat messages, prompts, commit messages or docs** — they can break model/agent communication. Refer to them descriptively, e.g. "im_start/im_end special tokens".

## What this is
iOS app serving an **OpenAI-compatible HTTP endpoint** on LAN from an iPhone:
- `apple-afm` — Apple FoundationModels (built-in, zero download, implicit today — Phase 2.5 makes it a first-class selectable).
- `mlx:<repo>` — MLX quantized models downloaded from Hugging Face (`mlx-community`); exactly one loaded at a time.
Consumed by a macOS "Companion" client (Phase 3). Bonjour: `_oai._tcp.` on `:8080`. Plain HTTP, **no auth** — conscious decision, revisit before public launch (ROADMAP Phase 4b).

## Current state
- `feat/pocketserve-phase2` = Phase 2 code, **19 commits ahead of master, NOT merged**.
- Green on Mac: ModelKit **22/22**, OpenAICompat **50/50**; iOS Simulator `BUILD SUCCEEDED`.
- Device smoke passed end-to-end (import→download→load→mlx chat→409/429→unload→delete), with defects found live.
- `POST /v1/messages` (Anthropic shape) merged (PR #1). In-app **Czat** + **API** screens implemented (`feat/inapp-endpoints-chat`) — manual device test pending.
- **Start every new session from: [docs/HANDOFF-PHASE2-CLOSEOUT.md](docs/HANDOFF-PHASE2-CLOSEOUT.md)**.

## BACKLOG (user-requested — carry across sessions, do not drop)
- [ ] **F1 — think-span leak (HIGH):** Qwen3 emits its chain-of-thought wrapped in im_start/im_end special tokens *raw* into `content` and SSE on every mlx chat. Fix: strip the think span (streaming filter in `MLXEngine.stream`, chunk-boundary safe) or disable thinking via chat template / `GenerateParameters`. Add MLXEngine-level test using synthetic chunk sequences (simulate tags split across chunks). Confirmed live 2026-09-20.
- [ ] **F2 — error message leak (MED):** error JSON `message` shows Swift enum dumps like `invalidRequest("model nie znaleziony")`. Fix: give `ServerAPIError` a `userMessage` accessor (associated-value text where present, else the `type` token) and send it in `HTTPServer` (`"\(e)"` → `e.userMessage`). 2026-09-20.
- [ ] **Screen keep-awake (HIGH, moved into Phase 2.5):** screen timeout suspends the app and kills the server (confirmed live). Add toggle "Keep screen awake while serving" → `UIApplication.shared.isIdleTimerDisabled` (set on server start, reset on stop/background).
- [ ] **Apple models first-class (MED):** visible "Apple Intelligence (apple-afm)" card in Models UI with availability status + onboarding when Apple Intelligence is off in system Settings.
- [ ] **Translate the iPhone app to English (REQUIRED before public launch):** see [docs/LOCALIZATION.md](docs/LOCALIZATION.md) and ROADMAP Phase 4a. User intends a public release.
- [ ] Phase 4b: LAN auth/pairing decision, free-space preflight, crash sweep, App Store assets.

## Layer rules (enforced by review; CI cannot check the MLX parts)
1. `Packages/ModelKit` — Foundation + CryptoKit only. No UIKit/MLX/OpenAICompat. Tests run on Mac.
2. `Packages/OpenAICompat` — Foundation + Network only. **Never imports ModelKit** — management is injected via `ServerExtension`; bridging lives in the app (`ModelsViewModel.bridge(_:op:)`).
3. App target `PocketServe1` — the only UIKit/SwiftUI/MLX/FoundationModels home.
4. Model ids: `mlx:<repo>` end-to-end (record id, engine id, /v1/models, chat dispatch); `apple-afm`; placeholder `mlx:none` never listed, never routable.
5. Error tokens (spec §5): load-not-ready `download_not_ready`, unload-not-loaded `model_not_loaded`, delete-loaded `model_loaded`, busy `server_busy`, memory `memory_pressure`; unknown-id: load→400, delete→404.

## Environment quirks (this machine)
- `/usr/local/bin/swift` and `rg` are broken shims → always `PATH=/usr/bin:$PATH swift …`; use built-in grep.
- Tests: `PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit` / `.../OpenAICompat`.
- Build: `xcodebuild -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 -destination 'generic/platform=iOS Simulator' build`.
- Device: iPhone 18 Pro Max, `192.168.68.27:8080` (IP can change — re-scan via Bonjour `_oai._tcp._`).
- **Keep Xcode scheme diagnostics OFF** (GPU Frame Capture: Disabled, Metal API Validation off) — they made the whole UI lag seconds per interaction; confirmed 2026-09-20.
- Sources live directly in `PocketServe1/PocketServe1/` (synchronized root group — no mirroring; old `PocketServe/PocketServe/` mirror deleted in `ca257d6`).

## Conventions
- SwiftUI on iOS 26 target (Xcode 27 beta toolchain): `import Combine` explicitly when using `@Published`; `NetService(port: Int32)`.
- mlx pins in pbxproj: mlx-swift-examples 2.29.1 (products MLXLLM + MLXLMCommon), mlx-swift 0.29.1 transitive. `chunk` is incremental → SSE passthrough. contextWindow constant 8192 (Qwen3 config allows more — confirm when convenient, not blocking).
- HF: info API requires `?blobs=true` for sizes/lfs.oids; mlx fingerprint = `quantization` key in config.json (not the literal word "mlx").
- Runbooks in `PocketServe/*.md`; phase specs/plans in `docs/superpowers/`; living docs at `docs/` top level.


