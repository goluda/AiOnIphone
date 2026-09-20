# iOS UI Polish — English i18n, Models swipe UX, request mini-log

Date: 2026-09-20 · Status: approved-for-planning (user delegated decisions) · Owner: PocketServe1 app + ModelKit + OpenAICompat

## Problem
1. Entire iPhone UI is Polish; public launch requires English (ROADMAP 4a started early by user request).
2. Models screen is broken-feeling: **every** button press (load/delete) can show the same alert "pobieranie już w toku". No visible state for "model is loading into memory"; user cannot reliably load or delete a downloaded model.
3. Home screen gives no feedback whether HTTP requests are arriving/being served.

## Root cause of #2 (code-verified)
- `DownloadCoordinator` guards `load(id:)` **and** `delete(id:)` with one shared flag `loadSlotBusy`, and both throw `DownloadAPIError.downloadInProgress` → `humanize` renders "pobieranie już w toku" for load/unload/delete alike (KNOWN_ISSUES F2 family — misleading token).
- `HFDownloader.start` keeps `status = .downloading` while awaiting file downloads; `URLSession` tasks have **no explicit timeout** → a stalled file on flaky LAN/WAN parks the actor forever, status never reaches `.failed`, and every later `start` returns `.inProgress` with the same message.
- UI has no `.loading-into-memory` state at all (`ModelRecord.state` has ready/failed/downloading; engine load is invisible), so pressing "Wczytaj" appears to do nothing.

## Approach decision
- **A (chosen):** surgical — English literals in-place (no String catalogs yet), SwiftUI `.swipeActions` on model rows with explicit state chips, per-operation busy flags in `DownloadCoordinator`, and an injected `onRequest` callback on `HTTPServer` feeding an app-level ring-buffer log.
- B (rejected): adopt `.xcstrings` catalogs now — right answer for 4b but triples churn of this pass; literals are one-for-one replacements hereafter extractable.
- C (rejected): poll `/x/...` for request stats — needless loopback traffic when events are already in-process.

## Design

### 1. English UI (app target `PocketServe1` + presets/humanize)
Replace **all** user-facing Polish literals with English in: `ContentView`, `ModelsView`, `EndpointsView`, `ChatView`, `ModelsViewModel.humanize/presets/bridge defaults`, `ServerModel` ("brak LAN" → "no LAN"), memory-pressure banner, alerts, dialogs, `navigationTitle/Subtitle`. Keep code comments as-is (English canonical already in most files). Set `CFBundleDevelopmentRegion = en` in Info.plist if not already. No `String(localized:)` migration yet — tracked as Phase 4b cleanup in LOCALIZATION.md.

### 2. Models screen — swipe UX + truthful states
Row state machine per `ModelRecord` + engine: `idle → downloading % → ready → loading… → loaded` and `failed`.
- **Leading swipe (swipe right):** LOAD when `ready`; UNLOAD when `loaded`. Hidden otherwise.
- **Trailing swipe (swipe left):** DELETE files, always `.destructive` + confirmation dialog ("Delete <repo> files?"). Blocked with clear message while `loading`/`loaded`.
- Inline buttons removed (swipes + row status chip only); retry stays a visible button on `failed` rows (discovery > purity there).
- Row shows: repo (headline), `quant · size · state chip`, spinner while `LOADING…` (engine load takes 5–30 s on device — this visibility is the core ask).
- `navigationSubtitle` = loaded model or "apple-afm only".
- Load/delete state lives in-process in the VM (`@Published loadingId/deletingId` set around `coordinator.load/delete` await) — no extra polling needed; existing 1 s poll still covers `downloading`.

### 3. Coordinator correctness (ModelKit)
- Replace single `loadSlotBusy` with explicit `operation: Idle | Loading | Deleting`; guards throw distinct cases: `.loadInProgress`, `.deleteInProgress` (`downloadInProgress` stays reserved for the downloader's real download-in-progress). **Wire tokens unchanged** (bridge maps the new cases to `downloadInProgress` → 409 `download_in_progress`; no `ServerExtension`/spec §5 drift) — the truthful per-op English text is what the in-app UI shows via `humanize`.
- Add `URLSessionConfiguration` with `timeoutIntervalForRequest = 60` / `resource = 600` to `HFDownloader` session (app composition) so a stalled file fails into `.failed` + retry instead of parking forever.
- `.notLoaded` on delete keeps `model_loaded` semantics (spec §5 unchanged); only the **misleading token** changes.

### 4. Request mini-log (OpenAICompat + app)
- OpenAICompat (Foundation+Network only): `public struct RequestEvent: Sendable { method, path, status, durationMs, model: String? }`; `HTTPServer.init(engines:extension:onRequest:)` optional callback. Emitted once per completed route (health, /v1/*, /x/*, errors incl. 429/409/404/400/500). Invoked from actor; consumers hop to MainActor themselves.
- App: `RequestLog: ObservableObject` (ring buffer, 100) created in `ServerModel`, injected at server construction; ContentView shows last 8 events (`HH:mm:ss  POST /v1/chat/completions 200 1.2s mlx`), monospaced, auto-scroll top = newest, "Clear" button, hidden when server stopped.

## Layer rules preserved
ModelKit: Foundation only. OpenAICompat: Foundation+Network, no ModelKit, callback is plain closure. UIKit/SwiftUI stay in app target.

## Testing
- ModelKit: coordinator op-exclusivity tests (delete during load → `deleteInProgress`, not `downloadInProgress`; unload-not-loaded → `.notLoaded`).
- OpenAICompat: `HTTPServerTests` assert `RequestEvent` emitted with correct method/path/status on 200, 404, 429, /x/*, and mid-stream engine error (durationMs ≥ 0).
- App: `PocketServe1Tests` — humanize returns distinct English per error case; preset strings English.
- Manual device checklist (RUN_ON_IPHONE): swipe load → chip LOADED → chat works → swipe unload → swipe delete removes files; mini-log shows the chat request; UI 100% English (grep for Polish diacritics must return nothing under `PocketServe1/`).

## Out of scope
Auth (4b), String catalogs, Bonjour changes, Companion changes, F1 think-span fix (separate backlog item, can land in same branch later).
