# PocketServe — Roadmap

Four phases. Phases are executed one at a time, each opening in a **fresh agent session**. A phase is "done" only when its acceptance checklist passes on a real iPhone (device smoke), not just on the simulator.

Legend: ✅ done · 🔶 in progress (code done, not merged) · ⬜ not started

---

## Phase 1 — Apple AFM endpoint ✅ (merged)
OpenAI-compatible `POST /v1/chat/completions` + `GET /v1/models` + `GET /health`, streaming (SSE) + non-stream, single-flight (429 when busy), Apple FoundationModels engine, `NWListener` server on `:8080`.
- Evidence: on master; merged. Design: `docs/superpowers/specs/2026-09-19-iphone-ai-companion-design.md`, plan `docs/superpowers/plans/2026-09-19-pocketserve-phase1-afm-endpoint.md`.

## Phase 2 — MLX engine + HF model management + iOS UI 🔶
Hugging Face downloader, persistent model store, download coordinator, `/x/*` management routes, `MLXEngine`, SwiftUI Models screen, model presets picker.
- Code: `feat/pocketserve-phase2` (**19 commits, NOT merged**). Tests green (ModelKit 22/22, OpenAICompat 50/50). Simulator builds.
- Device smoke: import → download → load → mlx chat → unload → delete all confirmed live.
- **Blockers before merge:** F1 (thinking-token leak), F2 (error-envelope leak). Product gap: F3 (background kill). Details → [KNOWN_ISSUES.md](KNOWN_ISSUES.md).
- Close-out instructions → [HANDOFF-PHASE2-CLOSEOUT.md](HANDOFF-PHASE2-CLOSEOUT.md).

## Phase 2.5 — Always-on server ⬜ (product-critical, was backlog)
Make the server survive the phone going idle. Today the OS suspends the app the moment the screen locks, killing `NWListener` — confirmed live 2026-09-20 (server 000 after screen dim).
### Scope
- `UIApplication.shared.isIdleTimerDisabled = true` **while the server runs** (server Start → set; server Stop / app background → reset). Expose as a user toggle: *"Keep screen awake while serving"* (default ON).
- **Apple AFM as a first-class model choice** in the Models UI: a visible card/selector `Apple Intelligence (apple-afm)` with availability status + onboarding when Apple Intelligence is off in system Settings (today `apple-afm` is implicit/fallback only).
### Acceptance
- [ ] Screen dimming does NOT drop the server; a LAN client stays connected across a lock/unlock.
- [ ] Idle timer re-enabled when server stops (no battery drain forever).
- [ ] Models screen shows an explicit Apple AFM card with live availability; graceful guidance if AFM disabled.
- [ ] BackgroundTask grant still correct around active generation (`BackgroundGuard` unchanged semantics).

## Phase 3 — macOS "Companion" client ⬜
Desktop client that discovers PocketServe via Bonjour (`NWBrowser("_oai._tcp.")`) and chats against it (stream rendering, model switcher, download management via `/x/*`).
### Scope (to be finalized in its brainstorm/design session)
- Service discovery + connect (`<IP>:8080`), auto-reconnect.
- Streaming chat UI; model selector fed by `/v1/models`.
- Optional: remote model management screens over `/x/*`.
- Suggested: SwiftPM or separate Xcode app; no iOS deps.
### Acceptance
- [ ] Companion finds phone on LAN with zero manual IP entry.
- [ ] Streaming chat works end-to-end against both `apple-afm` and `mlx:*`.
- [ ] Handles server-busy (429), model-not-ready (409) with clear UX.

## Phase 4 — Public launch / i18n / App Store ⬜
The user wants to make the iPhone app **public**.
### 4a. English localization (REQUIRED before public) — ⬜ from user 2026-09-20
- The iPhone app UI is currently **Polish-only** (all `Text("…")`, alerts, `humanize(...)`, preset notes, runbooks).
- Localize **all** user-facing strings to **English**; adopt `String(localized:)` / String catalogs (`Localizable.xcstring`); set `CFBundleDevelopmentRegion = en`, add `en` to known regions.
- Keep Polish as a secondary locale (don't delete — just stop being the default).
- Audit points: `ContentView`, `ModelsView`, `ModelsViewModel.humanize`, `ModelsViewModel.presets` notes, error strings surfaced to UI, Info.plist usage descriptions, App name, App Store copy.
### 4b. Hardening for public use
- **Threat model:** server is plain HTTP, **no auth** (conscious Phase‑1 decision). For a public/LAN-exposed app, add at minimum a LAN token or pairing code, and document the risk.
- Retention/limits: cap stored models by free space (`ModelStore.bytesFree()` already exists; wire a preflight).
- Crash-free: complete the device crash sweep (spec §8) incl. memory-pressure auto-unload on real devices.
- App Store metadata, icons, privacy nutrition labels, export-compliance (cryptography note for chat/TLS), versioning.
### Acceptance
- [ ] Full English UI, device set to English, zero Polish leakage in UI.
- [ ] Auth/pairing decision documented + implemented or explicitly accepted-risk.
- [ ] Crash sweep clean on target devices; App Store assets complete.

---
## Definition of Done (global)
- Both `swift test` packages green.
- iOS Simulator build succeeds.
- Device smoke (per phase) passes on iPhone 18 Pro Max (`192.168.68.27:8080`).
- Docs updated (`README`, `KNOWN_ISSUES`, `HANDOFF` / phase design+plan under `docs/superpowers/`).
- Merged to `master` with a concise conventional-commit message.
