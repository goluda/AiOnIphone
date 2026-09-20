# Design: in-app endpoints info + minimal chat window

Date: 2026-09-20
Status: approved verbally ("ok", user unavailable — decisions recorded)
Depends on: PR #1 merged (`/v1/messages` live, main @ d8a656a)

## Goal

Two additions to the iOS app (`PocketServe1`):
1. **API info screen** — static list of supported HTTP endpoints with the live base URL, so the user can copy curl targets without opening README.
2. **Minimal chat window** — user tests the loaded model directly on the phone (no Mac needed).

## Non-goals (YAGNI)

- No chat persistence (history lives in memory only, cleared on app restart).
- No Anthropic-shape client in-app (UI consumes `/v1/chat/completions` only; `/v1/messages` stays for external clients).
- No temperature/max-tokens controls. No image input. No auth (server is auth-less by design).
- No redesign of existing screens.

## Decisions (autonomous, user away)

- **Chat path: self-request over HTTP to `127.0.0.1:<port>`** (option A). Real request through `HTTPServer` = every chat turn also smoke-tests `/v1/chat/completions` + SSE end-to-end. ATS does not apply to literal loopback addresses; verify on simulator.
- Chat direct-to-engine (B) rejected: bypasses server, duplicates dispatch logic, tests nothing. DI-client-with-mock (C) rejected: overkill.
- SSE parsing lives in `Packages/OpenAICompat` as a pure, Mac-testable helper (chunk-boundary safe — same class of defect as BACKLOG F1).

## Architecture

```
ContentView
 ├── NavigationLink "Modele"  → ModelsView            (existing)
 ├── NavigationLink "API"     → EndpointsView         (NEW, static info)
 └── NavigationLink "Czat"    → ChatView              (NEW)
                                   └── ChatViewModel      (NEW, app target)
                                         ├── GET  /v1/models          (model picker)
                                         └── POST /v1/chat/completions (stream: true)
                                               └── URLSession.bytes → SSEParser (OpenAICompat)
```

Layer rules respected: `OpenAICompat` stays Foundation-only (parser has no UIKit/ModelKit); all SwiftUI + networking client live in app target `PocketServe1`.

## Components

### 1. `SSEParser.swift` (Packages/OpenAICompat, NEW)

```swift
public struct SSEEvent: Equatable, Sendable {
    public let event: String   // "message" | "content_block_delta" | "error" | ... ; default "message"
    public let data: String    // raw JSON payload line(s), joined; "[DONE]" passthrough
}

public struct SSEParser {
    public init()
    public mutating func feed(_ chunk: Data) -> [SSEEvent]
}
```

- Internal `String` buffer; append decoded chunk; emit complete events on blank-line separator (`\n\n`), tolerate `\r\n`.
- Multi-line `data:` in one event → joined with `\n`. Lines starting `:` are comments (ignored).
- Safe when a frame is split across chunks (the F1-class bug: never emit partial frames).
- Stateless with respect to semantics: it only frames; JSON decoding is caller's job.

### 2. `EndpointsView.swift` (app target, NEW)

Static `List`, sections mirror README's endpoint table:

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | health check |
| GET | `/v1/models` | lista modeli |
| POST | `/v1/chat/completions` | OpenAI shape, stream + JSON |
| POST | `/v1/messages` | Anthropic shape, stream + JSON |
| GET | `/x/models` | zarządzanie: lista |
| POST | `/x/download` | zarządzanie: import |
| GET | `/x/download/status` | zarządzanie: postęp |
| POST | `/x/models/load` \| `/x/models/unload` | zarządzanie: silnik |
| DELETE | `/x/models/{id}` | zarządzanie: usuń pliki |

Header section: base URL `http://{address}:{port}` from `ServerModel` (live `@Published`), monospaced, `.textSelection(.enabled)` + copy button (UIPasteboard). Offline → grey "serwer wyłączony" note. Error-codes footnote (429 busy, 409 not-ready, 404 unknown model, 400 bad request).

### 3. `ChatViewModel.swift` (app target, NEW)

`@MainActor final class ChatViewModel: ObservableObject`:

- `@Published var messages: [ChatMessage]` (roles: user/assistant; in-memory only)
- `@Published var availableModels: [String]`, `selectedModel: String`
- `@Published var draft: String`, `isStreaming: Bool`, `errorText: String?`
- `send()`: append user msg → `POST http://127.0.0.1:\(port)/v1/chat/completions` with body `{model, messages, stream: true}` → `URLSession.shared.bytes(for:)` → for each line feed `SSEParser` → on `ChatCompletionChunk` with `delta.content` append to streaming assistant bubble → on `finishReason`/`[DONE]` finalize.
- `stop()`: cancel the streaming `Task` (server keeps busy-gate until conn close — cancel triggers `conn.cancel()` server-side via FIN; acceptable, matches curl Ctrl-C behavior).
- `refreshModels()`: `GET /v1/models`, populate picker; default selection: `apple-afm` if present, else first.
- Error mapping to `errorText` (human, Polish labels OK per existing UI): `URLError.cannotConnect` → "Serwer wyłączony — włącz go na ekranie głównym"; HTTP 409 → "Model nie załadowany"; 429 → "Serwer zajęty"; 404 → "Nieznany model"; mid-stream `error` event → its `message`.
- Reuses `OpenAICompat` DTOs (`ChatCompletionRequest`, `ChatCompletionChunk`, `ModelsList`) — they are public already.

### 4. `ChatView.swift` (app target, NEW)

- `ScrollViewReader` messages list (user right/bubble, assistant left/plain), auto-scroll on new token.
- While streaming: last assistant bubble shows text + blinking cursor "▌".
- Bottom bar: `TextField` (`.lineLimit(1...4)`, send on submit / Return key), send ↔ stop button swap during streaming, `.disabled` when server offline or model list empty.
- `.toolbar` model picker (`Picker` menu of `availableModels`).
- `.task`: `refreshModels()`; re-refresh on appear after server start.
- Offline state: centered placeholder "Uruchom serwer, aby czatować" + Start button (calls `ServerModel.start()` — same action as home screen).

### 5. `ContentView.swift` (app target, MODIFY — surgical)

Add two `NavigationLink`s after "Modele": `"API"` → `EndpointsView(model: model)`, `"Czat"` → `ChatView(model: model)`. Nothing else changes.

## Error handling

- Every network error surfaces as inline `errorText` banner above input bar (dismissible), never a crash or silent fail.
- Busy-gate (429) is expected UX in chat when external client hits server — banner only, no retry loop.
- View model owns the stream `Task`; `ChatView.onDisappear` calls `stop()` so no orphaned requests when user navigates away.

## Testing

- **Mac (CI-checkable):** `SSEParserTests` in `OpenAICompatTests` — single frame, split-tag-across-chunks, multi-line data, comment lines, `\r\n`, `[DONE]`, `error` event frame. (New file, ~6 tests → OpenAICompat 62→68.)
- **Mac:** existing suites must stay green: ModelKit 22/22, OpenAICompat 62+6/68.
- **Simulator:** build green; manual: chat round-trip against built-in server (apple-afm), endpoints screen shows live URL.
- **Device smoke (user):** chat with `apple-afm` and one `mlx:*` model; Stop button mid-stream; 409 when switching to unloaded mlx repo.

## Success criteria

1. Chat window streams tokens live on device with `apple-afm` loaded.
2. Endpoints screen lists all 10 routes (9 table rows, load/unload combined) + copyable base URL.
3. `swift test` both packages green; simulator build green.
4. Zero new dependencies; layer rules intact (verified by grep: no UIKit/ModelKit in OpenAICompat).
