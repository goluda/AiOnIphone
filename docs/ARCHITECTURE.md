# PocketServe — Architecture

## Layer rules (enforced by review — CI can't check the MLX parts)
1. **`Packages/ModelKit`** — Foundation + CryptoKit only. No UIKit, no MLX, no OpenAICompat. Runs & tests on macOS. Owns: model state, HF client, downloader, store, coordinator (+ upcoming `ThinkStripper`).
2. **`Packages/OpenAICompat`** — Foundation + Network only. **Never imports ModelKit.** Server + engine-agnostic concerns; management + extra models are **injected** via `ServerExtension`.
3. **iOS app `PocketServe1`** — the only home of UIKit/SwiftUI/MLX/FoundationModels; bridges ModelKit ⇄ OpenAICompat (`ModelsViewModel.bridge(_:op:)`, `MLXLoading`).

> Rule 2 keeps the server testable on Mac without MLX. Do not weaken it to "simplify" a call.

## Request flow (`POST /v1/chat/completions`)
```
NWListener → parse → exact-id engine match
  apple-afm            → AFMEngine.stream (FoundationModels)
  mlx:<repo> loaded    → MLXEngine.stream (mlx-swift 2.29.1, incremental chunks)
  mlx:* unloaded       → 409 model_not_ready
  unknown              → 404
busy?  → 429 server_busy (single-flight)
stream → SSE chunks … [DONE]; mid-stream throw → error event + [DONE], clean FIN
```
Context window per engine (`apple-afm` 4096, `mlx` 8192) drives truncation before inference.

## Control plane (`/x/*`, injected `ServerExtension`)
Mounted without rebinding the listener (`HTTPServer.setExtension`). Never busy-gated.
```
GET  /x/models            records JSON (ModelStore)
GET  /x/download/status   current DownloadStatus (snake_case, non-zero bytes_total via ?blobs=true)
POST /x/download          start download (single-flight; 202 / 409 in-progress)
POST /x/models/load       load into MLX engine (202; 400 unknown; 409 memory_pressure)
POST /x/models/unload     unload (200; 409 model_not_loaded)
DELETE /x/models/{id}     delete files (200; 409 model_loaded; 404 unknown)
```
Errors: `ServerAPIError{httpStatus,type}`; message must be `userMessage`, not the Swift enum dump (see KNOWN_ISSUES F2).

## Data / persistence
- Documents/`models/<safeDir>` per repo; `ModelRecord` (id `mlx:<repo>`, state, quant, bytes, revision, loaded) persisted as snake_case+ISO8601 JSON.
- Download resumable via `<file>.part` + `Range`; SHA256 vs HF `lfs.oid`.
- `ModelStore` load guard 6 GB; `bytesFree()` for preflight. Restart resets `loaded=false` (model must reload).
- Exactly **one** MLX model resident at a time (`_container` + `_loadedId` under lock).

## Concurrency & lifecycle
- `HTTPServer`, `DownloadCoordinator`, `ModelStore`, `HFDownloader` are actors/segregated by lock.
- `busy` single-flight released via `defer` on every path.
- Streams counted (`activeStreams`) → `BackgroundGuard` grants a background task only during an active generation; `releaseStream` fires exactly once (onTermination + terminal points).
- Screen-off still kills the app server — permanent fix is Phase 2.5 keep-awake (KNOWN_ISSUES F3).

## Engines
- `AFMEngine` — FoundationModels; snapshots are cumulative → emitted as deltas.
- `MLXEngine` — `LLMModelFactory.shared.loadContainer(ModelConfiguration(directory:))` = fully offline; `generate(...)->AsyncStream<Generation>` where `Generation.chunk` is **incremental** → SSE passthrough. Unload waits for streams then `GPU.clearCache()`.

## Cross-component invariants
- Model id `mlx:<repo>` end-to-end (record ↔ engine.id ↔ /v1/models ↔ dispatch). Placeholder `mlx:none` never listed, never routable.
- OpenAI error `type` tokens stay English/stable regardless of UI locale.
- Server survives mount/unmount of management UI; UI pre-created off the tap path (perf `ca257d6`).

## Testing seams (why the layering exists)
- Server + parsers + SSE + truncation tested on **macOS** (`OpenAICompat` 50/50) with `MockEngine`.
- Downloader/coordinator/store tested on macOS with `FakeHF`/URLProtocol + tmp dirs (`ModelKit` 22/22).
- MLX/FoundationModels paths are device-only → covered by the device smoke runbook, not CI.
