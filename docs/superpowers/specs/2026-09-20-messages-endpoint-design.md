# Spec — `POST /v1/messages` (Anthropic-shape response, OpenAI-shape request)

Date: 2026-09-20
Scope: `Packages/OpenAICompat` only. No changes to engines, app target, `/x/*`, `/health`, `/v1/models`.
Depends on: Phase 2 code (merged into `main`; server green: ModelKit 22/22, OpenAICompat 50/50).

## Goal

Expose `POST /v1/messages` on the same listener as `/v1/chat/completions`. The request body
is the existing OpenAI-shape JSON; the response (JSON and SSE) uses Anthropic Messages API
naming so a client can parse it with Anthropic-style code while sending OpenAI-style payloads.

Decisions locked with the user:
- Request: OpenAI-shape only (`{model, messages, stream, temperature, max_tokens}`). Native
  Anthropic request bodies (top-level `system`, content blocks) are **not** accepted (400).
  Headers `x-api-key` / `anthropic-version` are ignored (LAN, no auth — AGENTS.md).
- Non-stream response: Anthropic-shape JSON.
- Streaming response: full Anthropic SSE event sequence (not OpenAI chunks, no `[DONE]`).

## Architecture

Approach: shared pipeline + thin Anthropic serializer (chosen over duplicated route or a
generic `WireFormat` protocol abstraction — YAGNI for two endpoints).

1. Extract the body of the existing `/v1/chat/completions` handler in `HTTPServer.route`
   verbatim into a private method:
   `runInference(_ request: ChatCompletionRequest, _ conn: NWConnection, wire: WireFormat)`.
   Pipeline unchanged: busy-gate (429) → exact-match engine lookup (404 / 409
   `model_not_ready` per spec §6 semantics) → `min(max_tokens, contextWindow)` →
   `ContextTruncator` → `PromptBuilder` → `for try await engine.stream(prompt:params:)`.
2. `enum WireFormat { case openai, anthropic }` (internal to OpenAICompat) selects the encoder
   for tokens, end-of-stream, and error envelope.
3. `route` gains: `if req.method == "POST", req.path == "/v1/messages"` → decode
   `ChatCompletionRequest` (same DTO, same defaults) → `runInference(..., wire: .anthropic)`.
4. New files in `Sources/OpenAICompat/`:
   - `AnthropicModels.swift` — DTOs: `AnthropicMessageResponse`, `AnthropicContentBlock`,
     `AnthropicUsage`, `AnthropicErrorBody`.
   - `AnthropicSSEEncoder.swift` — encodes the six SSE events below.
5. `InferenceEngine` protocol: **no change**. Engines (AFM/MLX) stay format-agnostic.
6. Layer rules hold: Foundation + Network only; no ModelKit import.

Existing behavior of `/v1/chat/completions` must remain bit-for-bit identical; the 50
existing OpenAICompat tests passing unmodified is the refactor gate.

## Wire format

### Non-streaming response (200)

```json
{
  "id": "msg_<uuid8>",
  "type": "message",
  "role": "assistant",
  "model": "<requested model id>",
  "content": [{ "type": "text", "text": "<full output>" }],
  "stop_reason": "end_turn",
  "stop_sequence": null,
  "usage": { "input_tokens": 123, "output_tokens": 45 }
}
```

- `id`: prefix `msg_` + 8 chars (parallel to `chatcmpl-` today).
- `stop_reason`: `"end_turn"` when the engine stream ends naturally (the only case today,
  since the pipeline ends its stream without a length-marker signal); `"max_tokens"` if/when
  an engine signals truncation. Placeholder-free mapping: natural end → `end_turn`.
- `usage`: same `TokenCounter.approximate` values as chat completions, renamed fields.

### Streaming response (`stream: true`)

Header: `HTTP/1.1 200 OK`, `Content-Type: text/event-stream`, `Cache-Control: no-cache`,
`Connection: close` (as today). Event sequence, each as `event: <name>\ndata: <json>\n\n`:

1. `message_start` — `{"type":"message_start","message":{"id":"msg_…","type":"message","role":"assistant","model":"…","content":[],"usage":{"input_tokens":N,"output_tokens":0}}}`
2. `content_block_start` — `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`
3. `ping` — `{"type":"ping"}`
4. per engine token: `content_block_delta` — `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"<token>"}}`
5. `content_block_stop` — `{"type":"content_block_stop","index":0}`
6. `message_delta` — `{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":M}}`
7. `message_stop` — `{"type":"message_stop"}`

- No `data: [DONE]` (OpenAI-only sentinel).
- Engine chunks are incremental (AGENTS.md convention) → passthrough into `text_delta`.

## Error handling

Same trigger points and HTTP statuses as `/v1/chat/completions`; envelope in Anthropic shape:
`{"type":"error","error":{"type":"<anthropic error type>","message":"<token>"}}`.

| Situation | HTTP | `error.type` | `message` |
|---|---|---|---|
| busy (second concurrent request) | 429 | `rate_limit_error` | `server_busy` |
| unknown model id | 404 | `not_found_error` | `model_not_found` |
| owned prefix, not loaded (mlx) | 409 | `invalid_request_error` | `model_not_ready` |
| malformed request JSON | 400 | `invalid_request_error` | parse detail |
| engine throws before stream | 500 | `api_error` | localized description |
| engine throws mid-stream | (200 open) | `error` event then close | message |

Mid-stream failure: send `event: error` with the error body, then close the stream cleanly
(no RST) — mirrors the existing I-1 behavior for chat completions.

`/x/*` routes, `/health`, `/v1/models`: untouched.

## Testing

Mac only (`PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat`).

New `MessagesRoutesTests.swift` (reuses existing mock-engine harness):
1. Non-stream `/v1/messages` → assert `type:"message"`, `role`, `content[0].type=="text"`,
   non-empty `content[0].text`, `stop_reason=="end_turn"`, `usage.input_tokens > 0`.
2. Stream `/v1/messages` → assert full event order `message_start` → `content_block_start` →
   `ping` → N × `content_block_delta` → `content_block_stop` → `message_delta` → `message_stop`;
   concatenated delta text equals expected mock output; no `[DONE]` present.
3. Gate reuse: second concurrent request → 429 `rate_limit_error`; unknown id → 404;
   unloaded mlx-prefixed id → 409 with `model_not_ready` in message.
4. Malformed body → 400 `invalid_request_error`.

New `AnthropicSSEEncoderTests.swift`:
5. Frame encoding: each event emits exactly `event: <name>\ndata: <compact json>\n\n`;
   JSON keys present per wire format above.

Refactor gate:
6. All existing OpenAICompat tests pass **unmodified** (chat-completions behavior unchanged).

Build gate:
7. `xcodebuild -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1
   -destination 'generic/platform=iOS Simulator' build` → `BUILD SUCCEEDED`.

Device re-smoke (runbook): append `/v1/messages` curl (stream + non-stream) to
`PocketServe/RUN_ON_IPHONE_PHASE2.md` §4 for the next on-device pass.

## Out of scope

- Native Anthropic request bodies (system field, content blocks, tools).
- Tool use / vision blocks; thinking/reasoning blocks (see F1 backlog — separate fix).
- Auth headers; `count_tokens` endpoint; multiple content blocks; OpenAI `n>1`.

## Follow-ups

- Companion (Phase 3) client: add an Anthropic-shape parser mode pointed at `/v1/messages`.
- If a third wire format ever appears, revisit the `WireFormat` abstraction then — not before.
