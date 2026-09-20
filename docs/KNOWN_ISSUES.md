# PocketServe — Known Issues & Live-Discovered Fixes

Severity: **critical** (blocks device flow) · **high** (visible defect on every use) · **med** · **low**.

## Open

### F1 — Think-span leak in mlx completions (HIGH)
- **Root cause:** mlx-swift `NaiveStreamingDetokenizer` does not skip special tokens here; the chat template keeps the "thinking" span in the output for this quant.
- **Fix (preferred):** stateful streaming filter in `MLXEngine.stream` — when the opener tag arrives (possibly split across chunks), drop everything until the closer completes. Keep it allocation-light. **Alternative:** disable thinking in chat template / `GenerateParameters` if exposed.
- **Test:** ModelKit-level `ThinkStripper` unit tests with synthetic chunk sequences (tags split at every offset 1..n-1), then wire into MLXEngine + one OpenAICompat-level test (MockEngine emits tagged stream → client sees clean content).

### F2 — Swift enum leak in error envelope (MED)
- **Seen live 2026-09-20:** `{"error":{"message":"invalidRequest(\"model nie znaleziony\")","type":"invalid_request_error"}}` — `HTTPServer` renders `"\(e)"`.
- **Fix:** `ServerAPIError.userMessage` → associated text (`invalidRequest`, `failed`) else `type` token; HTTPServer `/x/*` catch sends `e.userMessage` (two call sites in `HTTPServer.route`). Add XRoutesTests asserting clean `message`.

### F3 — Screen timeout kills the server (HIGH, → Phase 2.5 product task)
- **Confirmed live 2026-09-20:** phone auto-dim → iOS suspends the app → `NWListener` dead (curl 000). Wakes → server gone (app must restart it).
- **Fix:** `UIApplication.shared.isIdleTimerDisabled = true` while serving + user toggle "Keep screen awake while serving" (Phase 2.5 scope, see ROADMAP).

### F4 — RequestParser ignores `Transfer-Encoding: chunked` (MED)
- **Seen live 2026-09-20 (Companion):** .NET `JsonContent` posts chunked; parser computes `need` only from `content-length` → body parses as empty → chat POSTs fail `400 invalid_request_error`. Proof: raw capture shows `Transfer-Encoding: chunked` + `iPhone + JsonContent: 400` vs `StringContent → 200`.
- **Client-side fixed** (Companion serializes with Content-Length). **Server-side open:** decode chunked framing in `RequestParser.receive` (or reject chunked explicitly with a clear `411 Length Required`). Any chunked client (curl `-H 'Transfer-Encoding: chunked'`, other SDKs) currently gets a misleading 400.

### Auth gap (by design → revisit Phase 4b)
- Plain HTTP, **no auth**, LAN-only assumption. Before public launch decide: pairing code / bearer token / explicit accepted-risk doc.

## Fixed (kept for context — don't reintroduce)

| ID  | Defect                                                                               | Fix commit                                              |
| --- | ------------------------------------------------------------------------------------ | ------------------------------------------------------- |
| C-1 | mlx fingerprint false-negative (real quantized configs lack "mlx" in config.json)    | `edc4425` — check `quantization` key + safetensors gate |
| C-2 | HF info fetch without `?blobs=true` → sizes/oids absent, checksums silently dead     | `edc4425`                                               |
| —   | Mid-stream engine throw → bare TCP reset                                             | `4df4c9e` — SSE error event + `[DONE]` then clean FIN   |
| —   | listener rebind on Models-screen mount (UI lag)                                      | `ca257d6` — `HTTPServer.setExtension`, no rebind        |
| —   | single-flight / `alreadyReady` re-download of ready repo                             | `edc4425` idempotent · `292ef78` atomic guard           |
| —   | spec §5 token drift (`download_not_ready`, `model_loaded`, unknown-id 400/404 split) | `fdd635a` `ce9536b` `ac29944`                           |
| —   | chunk cumulativity assumption (2.29.1 chunks are **incremental**)                    | `4586371` passthrough                                   |
| —   | BackgroundGuard didn't cover MLX streams                                             | `ac29944`                                               |
| —   | retry-import used stale text field instead of record repo                            | `ac29944`                                               |
| —   | Companion chat 400: chunked body invisible to iOS RequestParser                      | fix/companion-chunked-body — StringContent + CL; regression test asserts CL before body read |

## Residual minor (low priority, optional)
- **M-1** resume progress bar can undercount `.part` bytes on resume (cosmetic).
- **M-3** memory-pressure mechanism is `didReceiveMemoryWarningNotification` (spec §3 named `DispatchSource(.warning)`) — functionally equivalent on iOS; banner never clears until refresh. Record as spec deviation.
- **M-4** `PocketServe/` still hosts the Phase‑1 legacy runbook dir — keep as history, code mirror gone (`ca257d6`).
- **M-5** no inline repo-id validation in TextField — alert-only (network never hit).
- **M-6** spec §8 model name `Qwen3-1.7B-4bit-4bit` is a typo; runbook name `Qwen3-1.7B-4bit` is the live/correct one.
- **Flaky-risk tests (timing):** `testXRoutesNotBusyGated` (medium), legacy 429/health/disconnect-window tests (low-med), `testInProgressPassthrough` (low), `testResumeAfterFailureUsesPartFile` (SDK-sensitive). Keep 200/150 ms windows generous when touching them.
