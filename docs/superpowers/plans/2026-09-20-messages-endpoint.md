# `/v1/messages` Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `POST /v1/messages` to the PocketServe HTTP server: OpenAI-shape request bodies in, Anthropic Messages-shape responses (JSON + SSE) out.

**Architecture:** Extract the `/v1/chat/completions` pipeline in `HTTPServer.route` into a shared private `runInference(_:conn:wire:)`; a `WireFormat` enum selects the OpenAI vs Anthropic serializer. New files `AnthropicModels.swift` (DTOs) and `AnthropicSSEEncoder.swift` (SSE frames) live in `Packages/OpenAICompat`. `InferenceEngine` is untouched — engines stay format-agnostic.

**Tech Stack:** Swift, XCTest, `Network.framework` (NWListener/NWConnection), Foundation only.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-20-messages-endpoint-design.md`. Locked: request OpenAI-shape ONLY (any other body shape → existing 400 path); responses Anthropic-shape; streaming = Anthropic SSE event sequence, **no** `data: [DONE]`.
- Layer rules (AGENTS.md): `Packages/OpenAICompat` = Foundation + Network only; never imports ModelKit; no UIKit.
- `/v1/chat/completions` byte-identical behavior required — all pre-existing OpenAICompat tests must pass **unmodified**.
- `/health`, `/v1/models`, `/x/*`: untouched.
- Env quirk: always `PATH=/usr/bin:$PATH swift …`; bare `swift`/`rg` are broken shims.
- English for code/comments/commits. **Never write raw ChatML special-token literals** anywhere (AGENTS.md).
- Test: `PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat`
- Build: `xcodebuild -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 -destination 'generic/platform=iOS Simulator' build`

## File Structure

| File                                                                           | Action | Responsibility                                                                        |
| ------------------------------------------------------------------------------ | ------ | ------------------------------------------------------------------------------------- |
| `Packages/OpenAICompat/Sources/OpenAICompat/AnthropicModels.swift`             | Create | Anthropic response DTOs                                                               |
| `Packages/OpenAICompat/Sources/OpenAICompat/AnthropicSSEEncoder.swift`         | Create | SSE frame encoder for Anthropic events                                                |
| `Packages/OpenAICompat/Tests/OpenAICompatTests/AnthropicSSEEncoderTests.swift` | Create | Encoder unit tests                                                                    |
| `Packages/OpenAICompat/Sources/OpenAICompat/HTTPServer.swift`                  | Modify | `WireFormat`, `runInference` extraction, wire-aware `sendError`, `/v1/messages` route |
| `Packages/OpenAICompat/Tests/OpenAICompatTests/MessagesRoutesTests.swift`      | Create | Route tests: JSON, SSE sequence, gates 429/404/409, 400, mid-stream error             |
| `PocketServe/RUN_ON_IPHONE_PHASE2.md`                                          | Modify | §4: add `/v1/messages` device smoke step                                              |

SwiftPM auto-discovers new files in `Sources/`/`Tests/` — no `Package.swift` edits.

---

### Task 1: Anthropic DTOs + SSE encoder (additive, unit-tested)

**Files:**
- Create: `Packages/OpenAICompat/Sources/OpenAICompat/AnthropicModels.swift`
- Create: `Packages/OpenAICompat/Sources/OpenAICompat/AnthropicSSEEncoder.swift`
- Test: `Packages/OpenAICompat/Tests/OpenAICompatTests/AnthropicSSEEncoderTests.swift`

**Interfaces:**
- Consumes: Foundation only.
- Produces (used by Task 2):
  - `AnthropicContentBlock(type: String = "text", text: String)`
  - `AnthropicUsage(inputTokens: Int, outputTokens: Int)` → JSON `input_tokens`/`output_tokens`
  - `AnthropicMessageResponse(id:model:content:stopReason:usage:)` → JSON with `type:"message"`, `role:"assistant"`, `stop_sequence:null`
  - `AnthropicErrorBody(errorType:message:)` → `{"type":"error","error":{"type":…,"message":…}}`
  - `AnthropicSSEEncoder.messageStart(id:model:usage:)`, `.contentBlockStart()`, `.ping()`, `.contentBlockDelta(text:)`, `.contentBlockStop()`, `.messageDelta(stopReason:outputTokens:)`, `.messageStop()`, `.error(message:type:)` — each `throws -> Data`, one `event: <name>\ndata: <json>\n\n` frame.

- [ ] **Step 1: Write the failing encoder tests**

Create `Packages/OpenAICompat/Tests/OpenAICompatTests/AnthropicSSEEncoderTests.swift`:

```swift
import XCTest
@testable import OpenAICompat

final class AnthropicSSEEncoderTests: XCTestCase {

    private func decodeFrame(_ data: Data, expectedEvent: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("event: \(expectedEvent)\ndata: "), "frame prefix: \(text.prefix(40))", file: file, line: line)
        XCTAssertTrue(text.hasSuffix("\n\n"), "frame terminator", file: file, line: line)
        let json = text.dropFirst("event: \(expectedEvent)\ndata: ".count).dropLast(2)
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testMessageStartFrame() throws {
        let f = decodeFrame(try AnthropicSSEEncoder.messageStart(id: "msg_a", model: "m",
            usage: AnthropicUsage(inputTokens: 7, outputTokens: 0)), expectedEvent: "message_start")
        let m = f["message"] as? [String: Any] ?? [:]
        XCTAssertEqual(f["type"] as? String, "message_start")
        XCTAssertEqual(m["id"] as? String, "msg_a")
        XCTAssertEqual(m["type"] as? String, "message")
        XCTAssertEqual(m["role"] as? String, "assistant")
        XCTAssertEqual(m["model"] as? String, "m")
        XCTAssertEqual(m["content"] as? [Any], [])
        let u = m["usage"] as? [String: Any] ?? [:]
        XCTAssertEqual(u["input_tokens"] as? Int, 7)
        XCTAssertEqual(u["output_tokens"] as? Int, 0)
    }

    func testContentBlockFrames() throws {
        let start = decodeFrame(try AnthropicSSEEncoder.contentBlockStart(), expectedEvent: "content_block_start")
        XCTAssertEqual(start["index"] as? Int, 0)
        let block = start["content_block"] as? [String: Any] ?? [:]
        XCTAssertEqual(block["type"] as? String, "text")
        XCTAssertEqual(block["text"] as? String, "")

        let delta = decodeFrame(try AnthropicSSEEncoder.contentBlockDelta(text: "Hello"), expectedEvent: "content_block_delta")
        XCTAssertEqual(delta["index"] as? Int, 0)
        let d = delta["delta"] as? [String: Any] ?? [:]
        XCTAssertEqual(d["type"] as? String, "text_delta")
        XCTAssertEqual(d["text"] as? String, "Hello")

        XCTAssertEqual(decodeFrame(try AnthropicSSEEncoder.contentBlockStop(), expectedEvent: "content_block_stop")["index"] as? Int, 0)
    }

    func testMessageDeltaPingAndStopFrames() throws {
        let f = decodeFrame(try AnthropicSSEEncoder.messageDelta(stopReason: "end_turn", outputTokens: 5), expectedEvent: "message_delta")
        let d = f["delta"] as? [String: Any] ?? [:]
        XCTAssertEqual(d["stop_reason"] as? String, "end_turn")
        XCTAssertTrue(d.keys.contains("stop_sequence"))
        XCTAssertNil(d["stop_sequence"])
        XCTAssertEqual((f["usage"] as? [String: Any])?["output_tokens"] as? Int, 5)

        XCTAssertEqual(decodeFrame(try AnthropicSSEEncoder.messageStop(), expectedEvent: "message_stop")["type"] as? String, "message_stop")
        XCTAssertEqual(decodeFrame(try AnthropicSSEEncoder.ping(), expectedEvent: "ping")["type"] as? String, "ping")
    }

    func testErrorFrame() throws {
        let f = decodeFrame(try AnthropicSSEEncoder.error(message: "boom", type: "api_error"), expectedEvent: "error")
        XCTAssertEqual(f["type"] as? String, "error")
        let e = f["error"] as? [String: Any] ?? [:]
        XCTAssertEqual(e["type"] as? String, "api_error")
        XCTAssertEqual(e["message"] as? String, "boom")
    }

    func testResponseDTOKeys() throws {
        let resp = AnthropicMessageResponse(id: "msg_1", model: "mock",
            content: [AnthropicContentBlock(text: "hi")], stopReason: "end_turn",
            usage: AnthropicUsage(inputTokens: 2, outputTokens: 1))
        let j = (try? JSONSerialization.jsonObject(with: try JSONEncoder().encode(resp))) as? [String: Any] ?? [:]
        XCTAssertEqual(j["type"] as? String, "message")
        XCTAssertEqual(j["role"] as? String, "assistant")
        XCTAssertTrue(j.keys.contains("stop_sequence")); XCTAssertNil(j["stop_sequence"])
        XCTAssertEqual(j["stop_reason"] as? String, "end_turn")
        let b = (j["content"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(b["type"] as? String, "text")
        XCTAssertEqual(b["text"] as? String, "hi")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat 2>&1 | head -30`
Expected: compile error `cannot find 'AnthropicSSEEncoder' in scope` (DTOs missing).

- [ ] **Step 3: Write DTOs**

Create `Packages/OpenAICompat/Sources/OpenAICompat/AnthropicModels.swift`:

```swift
import Foundation

public struct AnthropicContentBlock: Codable, Sendable, Equatable {
    public let type: String
    public let text: String
    public init(type: String = "text", text: String) { self.type = type; self.text = text }
}

public struct AnthropicUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens"
        case outputTokens = "output_tokens" }
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens }
}

public struct AnthropicMessageResponse: Codable, Sendable {
    public let id: String
    public let type: String
    public let role: String
    public let model: String
    public let content: [AnthropicContentBlock]
    public let stopReason: String?
    public let stopSequence: String?
    public let usage: AnthropicUsage
    enum CodingKeys: String, CodingKey { case id, type, role, model, content, usage
        case stopReason = "stop_reason", stopSequence = "stop_sequence" }
    public init(id: String, model: String, content: [AnthropicContentBlock],
                stopReason: String?, usage: AnthropicUsage) {
        self.id = id; self.type = "message"; self.role = "assistant"; self.model = model
        self.content = content; self.stopReason = stopReason; self.stopSequence = nil; self.usage = usage
    }
}

public struct AnthropicErrorBody: Codable, Sendable {
    public struct ErrorDetail: Codable, Sendable { public let type: String; public let message: String }
    public let type: String
    public let error: ErrorDetail
    public init(errorType: String, message: String) {
        self.type = "error"; self.error = ErrorDetail(type: errorType, message: message) }
}
```

- [ ] **Step 4: Write SSE encoder**

Create `Packages/OpenAICompat/Sources/OpenAICompat/AnthropicSSEEncoder.swift`:

```swift
import Foundation

public enum AnthropicSSEEncoder {
    private static func frame(_ event: String, _ payload: any Encodable) throws -> Data {
        Data("event: \(event)\ndata: ".utf8) + try JSONEncoder().encode(payload) + Data("\n\n".utf8)
    }

    public static func messageStart(id: String, model: String, usage: AnthropicUsage) throws -> Data {
        struct Message: Encodable { let type: String; let id: String; let role: String; let model: String
            let content: [AnthropicContentBlock]; let usage: AnthropicUsage }
        struct Payload: Encodable { let type: String; let message: Message }
        return try frame("message_start", Payload(type: "message_start",
            message: Message(type: "message", id: id, role: "assistant", model: model, content: [], usage: usage)))
    }

    public static func contentBlockStart() throws -> Data {
        struct Payload: Encodable { let type: String; let index: Int; let content_block: AnthropicContentBlock }
        return try frame("content_block_start", Payload(type: "content_block_start", index: 0, content_block: .init(text: "")))
    }

    public static func ping() throws -> Data {
        struct Payload: Encodable { let type: String }
        return try frame("ping", Payload(type: "ping"))
    }

    public static func contentBlockDelta(text: String) throws -> Data {
        struct Delta: Encodable { let type: String; let text: String }
        struct Payload: Encodable { let type: String; let index: Int; let delta: Delta }
        return try frame("content_block_delta", Payload(type: "content_block_delta", index: 0, delta: Delta(type: "text_delta", text: text)))
    }

    public static func contentBlockStop() throws -> Data {
        struct Payload: Encodable { let type: String; let index: Int }
        return try frame("content_block_stop", Payload(type: "content_block_stop", index: 0))
    }

    public static func messageDelta(stopReason: String, outputTokens: Int) throws -> Data {
        struct Delta: Encodable { let stop_reason: String; let stop_sequence: String? }
        struct Payload: Encodable { let type: String; let delta: Delta; let usage: AnthropicUsage }
        return try frame("message_delta", Payload(type: "message_delta",
            delta: Delta(stop_reason: stopReason, stop_sequence: nil),
            usage: AnthropicUsage(inputTokens: 0, outputTokens: outputTokens)))
    }

    public static func messageStop() throws -> Data {
        struct Payload: Encodable { let type: String }
        return try frame("message_stop", Payload(type: "message_stop"))
    }

    public static func error(message: String, type: String = "api_error") throws -> Data {
        try frame("error", AnthropicErrorBody(errorType: type, message: message))
    }
}
```

- [ ] **Step 5: Run full suite — expect green**

Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat`
Expected: `Test Suite 'All tests' passed` — 50 pre-existing + 6 new = **56/56**.

- [ ] **Step 6: Commit**

```bash
git add Packages/OpenAICompat/Sources/OpenAICompat/AnthropicModels.swift \
        Packages/OpenAICompat/Sources/OpenAICompat/AnthropicSSEEncoder.swift \
        Packages/OpenAICompat/Tests/OpenAICompatTests/AnthropicSSEEncoderTests.swift
git commit -m "feat(openai-compat): add Anthropic message DTOs and SSE frame encoder"
```

---

### Task 2: Route `/v1/messages` through shared `runInference` (JSON + SSE + errors)

**Files:**
- Modify: `Packages/OpenAICompat/Sources/OpenAICompat/HTTPServer.swift` (tail of `route`, `sendError`; add `WireFormat`, `runInference`, `anthropicErrorType`)
- Test: `Packages/OpenAICompat/Tests/OpenAICompatTests/MessagesRoutesTests.swift`

**Interfaces:**
- Consumes (Task 1): `AnthropicMessageResponse`, `AnthropicErrorBody`, `AnthropicContentBlock`, `AnthropicUsage`, `AnthropicSSEEncoder.*`.
- Consumes (existing): `ChatCompletionRequest`, `ContextTruncator.truncate`, `PromptBuilder.prompt`, `TokenCounter.approximate`, `SSEEncoder.encode/done/encodeError`, `InferenceEngine` (+`prefixOwned`/`listedModel`), `CompletionResponse`/`Usage`/`ChatCompletionChunk`/`ChunkChoice`/`Delta`/`ResponseChoice`/`ChatMessage` (unchanged), `MockEngine`.
- Produces: working `POST /v1/messages` (both stream modes); `/v1/chat/completions` unchanged; `HTTPServer.WireFormat` (internal).

**Test-module notes:** all test files compile into ONE test module, so `PlaceholderMLXEngine` and `ThrowingEngine` (internal in `HTTPServerTests.swift`) are visible here. The raw-socket helpers there are `private` (file-scoped) → self-contained copies included below.

- [ ] **Step 1: Write the failing route tests**

Create `Packages/OpenAICompat/Tests/OpenAICompatTests/MessagesRoutesTests.swift`:

```swift
import XCTest
import Network
@testable import OpenAICompat

final class MessagesRoutesTests: XCTestCase {
    private struct TestTimeout: Error {}

    private func post(_ port: UInt16, _ path: String, _ body: Data) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = body
        return r
    }

    private func messagesBody(model: String, stream: Bool = false) throws -> Data {
        try JSONEncoder().encode(ChatCompletionRequest(model: model,
            messages: [ChatMessage(role: "user", content: "siema")], stream: stream))
    }

    private func parseSSE(_ raw: String) -> [(String, [String: Any])] {
        raw.components(separatedBy: "\n\n").compactMap { frame in
            let lines = frame.components(separatedBy: "\n")
            guard let ev = lines.first(where: { $0.hasPrefix("event: ") })?.dropFirst(7),
                  let dl = lines.first(where: { $0.hasPrefix("data: ") })?.dropFirst(6),
                  let obj = try? JSONSerialization.jsonObject(with: Data(dl.utf8)) as? [String: Any]
            else { return nil }
            return (String(ev), obj)
        }
    }

    func testMessagesNonStreamingAnthropicJSON() async throws {
        let s = HTTPServer(engines: [MockEngine()]); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let (data, resp) = try await URLSession.shared.data(for: post(port, "/v1/messages", try messagesBody(model: "mock")))
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let r = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
        XCTAssertEqual(r.type, "message")
        XCTAssertEqual(r.role, "assistant")
        XCTAssertEqual(r.model, "mock")
        XCTAssertEqual(r.content.map(\.type), ["text"])
        XCTAssertEqual(r.content.first?.text, "To jest mock")
        XCTAssertEqual(r.stopReason, "end_turn")
        XCTAssertNil(r.stopSequence)
        XCTAssertGreaterThan(r.usage.inputTokens, 0)
        XCTAssertGreaterThan(r.usage.outputTokens, 0)
        XCTAssertTrue(r.id.hasPrefix("msg_"), r.id)
    }

    func testMessagesStreamEmitsFullAnthropicSequence() async throws {
        let s = HTTPServer(engines: [MockEngine()]); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let conn = try await rawConnect(port: port); defer { conn.cancel() }
        conn.send(content: rawPOST(path: "/v1/messages", body: try messagesBody(model: "mock", stream: true)), completion: .contentProcessed { _ in })
        let raw = String(decoding: try await receiveAll(conn), as: UTF8.self)
        XCTAssertTrue(raw.hasPrefix("HTTP/1.1 200"), raw)
        XCTAssertTrue(raw.contains("Content-Type: text/event-stream"))
        XCTAssertFalse(raw.contains("[DONE]"), "Anthropic SSE must not carry the OpenAI sentinel")

        let events = parseSSE(raw.components(separatedBy: "\r\n\r\n").last ?? raw)
        XCTAssertEqual(events.map(\.0), ["message_start", "content_block_start", "ping",
            "content_block_delta", "content_block_delta", "content_block_delta",
            "content_block_stop", "message_delta", "message_stop"]) // MockEngine yields 3 tokens ["To"," jest"," mock"]
        let text = events.filter { $0.0 == "content_block_delta" }
            .map { ($0.1["delta"] as? [String: Any])?["text"] as? String ?? "" }.joined()
        XCTAssertEqual(text, "To jest mock")
        let md = events.first { $0.0 == "message_delta" }?.1 ?? [:]
        XCTAssertEqual((md["delta"] as? [String: Any])?["stop_reason"] as? String, "end_turn")
        XCTAssertGreaterThan(((md["usage"] as? [String: Any])?["output_tokens"] as? Int) ?? 0, 0)
    }

    func testMessagesMidStreamErrorEmitsErrorEvent() async throws {
        let s = HTTPServer(engines: [ThrowingEngine()]); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let conn = try await rawConnect(port: port); defer { conn.cancel() }
        conn.send(content: rawPOST(path: "/v1/messages", body: try messagesBody(model: "boom", stream: true)), completion: .contentProcessed { _ in })
        let raw = String(decoding: try await receiveAll(conn), as: UTF8.self) // RST would throw in receiveAll
        XCTAssertTrue(raw.contains("event: content_block_delta"), "fragment before throw arrived")
        XCTAssertTrue(raw.contains("czesc"), raw)
        XCTAssertTrue(raw.contains("event: error"), raw)
        XCTAssertTrue(raw.contains("\"api_error\""), raw)
        XCTAssertFalse(raw.contains("event: message_stop"), raw)
        XCTAssertFalse(raw.contains("[DONE]"), raw)
    }

    func testMessagesUnknownModel404AnthropicEnvelope() async throws {
        let s = HTTPServer(engines: [MockEngine()]); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let (data, resp) = try await URLSession.shared.data(for: post(port, "/v1/messages", try messagesBody(model: "ghost")))
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 404)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"type\":\"error\""), text)
        XCTAssertTrue(text.contains("not_found_error"), text)
        XCTAssertTrue(text.contains("model_not_found"), text)
    }

    func testMessagesUnloadedMLXPrefixed409() async throws {
        let s = HTTPServer(engines: [MockEngine(), PlaceholderMLXEngine()])
        let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let (data, resp) = try await URLSession.shared.data(for: post(port, "/v1/messages", try messagesBody(model: "mlx:any")))
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 409) // owned prefix, not loaded → not 404
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("invalid_request_error"), text)
        XCTAssertTrue(text.contains("model_not_ready"), text)
    }

    func testMessagesMalformedBody400() async throws {
        let s = HTTPServer(engines: [MockEngine()]); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let (data, resp) = try await URLSession.shared.data(for: post(port, "/v1/messages", Data("not json".utf8)))
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("invalid_request_error"))
    }

    func testMessagesSecondConcurrentGets429AndBusyReleases() async throws {
        let s = HTTPServer(engines: [MockEngine(latency: .milliseconds(150))])
        let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let a = try await rawConnect(port: port); defer { a.cancel() }
        a.send(content: rawPOST(path: "/v1/messages", body: try messagesBody(model: "mock", stream: true)), completion: .contentProcessed { _ in })
        let head = try await rawReceive(a)
        XCTAssertTrue(String(decoding: head, as: UTF8.self).hasPrefix("HTTP/1.1 200")) // SSE head => busy acquired

        let (dataB, respB) = try await URLSession.shared.data(for: post(port, "/v1/messages", try messagesBody(model: "mock")))
        XCTAssertEqual((respB as? HTTPURLResponse)?.statusCode, 429)
        let textB = String(decoding: dataB, as: UTF8.self)
        XCTAssertTrue(textB.contains("rate_limit_error"), textB)
        XCTAssertTrue(textB.contains("server_busy"), textB)

        _ = try await receiveAll(a) // drain => busy released
        let (dataC, respC) = try await URLSession.shared.data(for: post(port, "/v1/messages", try messagesBody(model: "mock")))
        XCTAssertEqual((respC as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(AnthropicMessageResponse.self, from: dataC).content.first?.text, "To jest mock")
    }

    // MARK: - raw helpers (private copies; originals in HTTPServerTests.swift are file-scoped)

    private func rawConnect(port: UInt16) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TestTimeout() }
        let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        conn.start(queue: DispatchQueue(label: "raw-client-messages"))
        return try await withTimeout(5) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWConnection, any Error>) in
                conn.stateUpdateHandler = { (state: NWConnection.State) in
                    switch state {
                    case .ready: conn.stateUpdateHandler = nil; cont.resume(returning: conn)
                    case .failed(let e): conn.stateUpdateHandler = nil; cont.resume(throwing: e)
                    case .cancelled: conn.stateUpdateHandler = nil; cont.resume(throwing: NWError.posix(.ECANCELED))
                    default: break
                    }
                }
            }
        }
    }

    private func rawPOST(path: String, body: Data) -> Data {
        Data("POST \(path) HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    private func rawReceive(_ conn: NWConnection) async throws -> Data {
        try await withTimeout(5) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: data ?? Data()) }
                }
            }
        }
    }

    private func receiveAll(_ conn: NWConnection) async throws -> Data {
        var out = Data()
        do { while true { out.append(try await rawReceive(conn)) } } catch { return out }
    }

    private func withTimeout<T: Sendable>(_ seconds: Double = 10,
                                          _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw TestTimeout() }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat 2>&1 | grep -A2 "MessagesRoutesTests" | head -20`
Expected: failures like `("Optional(404)") is not equal to ("Optional(200)")` — `/v1/messages` currently falls through to the 404 guard.

- [ ] **Step 3: Implement — extract pipeline, add route, wire-aware errors**

In `HTTPServer.swift`, replace the whole tail of `route` — from the line

```swift
        guard req.method == "POST", req.path == "/v1/chat/completions" else {
```

through the end of `route` (the `sendJSON(conn, 200, try! JSONEncoder().encode(resp))` / `}` / `}` closing the method) — with:

```swift
        guard req.method == "POST", req.path == "/v1/chat/completions" || req.path == "/v1/messages" else {
            sendError(conn, 404, "not_found"); return
        }
        let wire: WireFormat = req.path == "/v1/messages" ? .anthropic : .openAI
        guard !busy else { sendError(conn, 429, "server_busy", wire: wire); return }
        let request: ChatCompletionRequest
        do { request = try JSONDecoder().decode(ChatCompletionRequest.self, from: req.body) }
        catch { sendError(conn, 400, "invalid_request_error", wire: wire); return }
        await runInference(request, conn, wire: wire)
    }

    // Shared pipeline for /v1/chat/completions (.openAI) and /v1/messages (.anthropic). Busy-gate held by caller.
    private func runInference(_ request: ChatCompletionRequest, _ conn: NWConnection, wire: WireFormat) async {
        // exact-match pomija placeholdery silników dynamicznych (np. "mlx:none" gdy niezaładowany)
        guard let engine = engines.first(where: { $0.id == request.model && ($0.listedModel != nil || $0.prefixOwned == nil) }) else {
            // dynamic-id silnik (mlx): prefiks czyj, ale model nie załadowany → 409 (spec §6), nie 404
            if engines.contains(where: { ($0.prefixOwned.map { request.model.hasPrefix($0) }) ?? false }) {
                sendError(conn, 409, "model_not_ready", wire: wire)
            } else {
                sendError(conn, 404, "model_not_found", wire: wire)
            }
            return
        }
        busy = true
        defer { busy = false }
        let maxTokens = min(request.maxTokens, engine.contextWindow)
        let kept = ContextTruncator.truncate(messages: request.messages, budgetTokens: engine.contextWindow - maxTokens).kept
        let prompt = PromptBuilder.prompt(from: kept)
        let params = GenerationParams(temperature: request.temperature, maxTokens: maxTokens)
        let id = "\(wire == .anthropic ? "msg_" : "chatcmpl-")\(UUID().uuidString.prefix(8))"
        let created = Int(Date().timeIntervalSince1970)
        let promptTokens = TokenCounter.approximate(prompt)
        if request.stream {
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8)
            conn.send(content: header, completion: .contentProcessed { _ in })
            do {
                if wire == .anthropic {
                    conn.send(content: try AnthropicSSEEncoder.messageStart(id: id, model: request.model,
                        usage: AnthropicUsage(inputTokens: promptTokens, outputTokens: 0)), completion: .contentProcessed { _ in })
                    conn.send(content: try AnthropicSSEEncoder.contentBlockStart(), completion: .contentProcessed { _ in })
                    conn.send(content: try AnthropicSSEEncoder.ping(), completion: .contentProcessed { _ in })
                    var out = ""
                    for try await token in engine.stream(prompt: prompt, params: params) {
                        out += token
                        conn.send(content: try AnthropicSSEEncoder.contentBlockDelta(text: token), completion: .contentProcessed { _ in })
                    }
                    conn.send(content: try AnthropicSSEEncoder.contentBlockStop(), completion: .contentProcessed { _ in })
                    conn.send(content: try AnthropicSSEEncoder.messageDelta(stopReason: "end_turn",
                        outputTokens: TokenCounter.approximate(out)), completion: .contentProcessed { _ in })
                    conn.send(content: try AnthropicSSEEncoder.messageStop(), completion: .contentProcessed { _ in conn.cancel() })
                } else {
                    for try await token in engine.stream(prompt: prompt, params: params) {
                        let chunk = ChatCompletionChunk(id: id, created: created, model: request.model,
                            choices: [.init(index: 0, delta: .init(content: token), finishReason: nil)])
                        conn.send(content: try SSEEncoder.encode(chunk), completion: .contentProcessed { _ in })
                    }
                    let end = ChatCompletionChunk(id: id, created: created, model: request.model,
                        choices: [.init(index: 0, delta: .init(content: nil), finishReason: "stop")])
                    conn.send(content: try SSEEncoder.encode(end), completion: .contentProcessed { _ in })
                    conn.send(content: SSEEncoder.done, completion: .contentProcessed { _ in conn.cancel() })
                }
            } catch {
                // I-1: silnik rzucił w trakcie streamu → error event + czyste zamknięcie (bez RST).
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                do {
                    if wire == .anthropic {
                        conn.send(content: try AnthropicSSEEncoder.error(message: msg), completion: .contentProcessed { _ in })
                        conn.send(content: Data("\n".utf8), completion: .contentProcessed { _ in conn.cancel() })
                    } else {
                        conn.send(content: SSEEncoder.encodeError(msg), completion: .contentProcessed { _ in })
                        conn.send(content: SSEEncoder.done, completion: .contentProcessed { _ in conn.cancel() })
                    }
                } catch { conn.cancel() }
            }
        } else {
            var full = ""
            do { for try await t in engine.stream(prompt: prompt, params: params) { full += t } }
            catch { sendError(conn, 500, "server_error", wire: wire); return }
            if wire == .anthropic {
                let resp = AnthropicMessageResponse(id: id, model: request.model,
                    content: [AnthropicContentBlock(text: full)], stopReason: "end_turn",
                    usage: AnthropicUsage(inputTokens: promptTokens, outputTokens: TokenCounter.approximate(full)))
                sendJSON(conn, 200, try! JSONEncoder().encode(resp))
            } else {
                let usage = Usage(promptTokens: promptTokens, completionTokens: TokenCounter.approximate(full))
                let resp = CompletionResponse(id: id, created: created, model: request.model,
                    choices: [.init(index: 0, message: ChatMessage(role: "assistant", content: full), finishReason: "stop")], usage: usage)
                sendJSON(conn, 200, try! JSONEncoder().encode(resp))
            }
        }
    }
```

Then replace the existing `sendError` with:

```swift
    enum WireFormat { case openAI, anthropic }

    private static func anthropicErrorType(status: Int) -> String {
        switch status {
        case 429: return "rate_limit_error"
        case 404: return "not_found_error"
        case 400, 409: return "invalid_request_error"
        default: return "api_error"
        }
    }

    private func sendError(_ conn: NWConnection, _ status: Int, _ type: String, wire: WireFormat = .openAI) {
        switch wire {
        case .openAI:
            sendJSON(conn, status, try! JSONEncoder().encode(OpenAIErrorBody(message: type, type: type)))
        case .anthropic:
            sendJSON(conn, status, try! JSONEncoder().encode(
                AnthropicErrorBody(errorType: Self.anthropicErrorType(status: status), message: type)))
        }
    }
```

Notes for the implementer:
- All pre-existing `sendError(conn, …)` call sites (health/models//x//404 fallthrough) compile unchanged via the `.openAI` default.
- The anthropic mid-stream `error` frame already ends `\n\n`; the extra `\n` send is belt-and-braces for frame-flush ordering before close — harmless, keep as written to mirror existing two-send pattern.
- SSE test parses after stripping the HTTP header block via `components(separatedBy: "\r\n\r\n").last`.

- [ ] **Step 4: Run full suite — expect green**

Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat`
Expected: `Test Suite 'All tests' passed` — **63/63** (50 pre-existing untouched + 6 Task 1 + 7 Task 2). If any pre-existing chat test fails, the refactor broke bit-for-bit parity — fix the extraction, do not "adjust" the old test.

- [ ] **Step 5: Commit**

```bash
git add Packages/OpenAICompat/Sources/OpenAICompat/HTTPServer.swift \
        Packages/OpenAICompat/Tests/OpenAICompatTests/MessagesRoutesTests.swift
git commit -m "feat(openai-compat): add POST /v1/messages with Anthropic-shape JSON and SSE"
```

---

### Task 3: Simulator build + device-smoke runbook step

**Files:**
- Modify: `PocketServe/RUN_ON_IPHONE_PHASE2.md` (§4)

**Interfaces:**
- Consumes: Task 2 route.
- Produces: device smoke coverage for `/v1/messages`.

- [ ] **Step 1: Simulator build gate**

Run: `xcodebuild -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **` (app target compiles; it links OpenAICompat with the new route).

- [ ] **Step 2: Document the device smoke step**

In `PocketServe/RUN_ON_IPHONE_PHASE2.md`, after §4 step 3 (chat MLX), insert a new step and renumber following steps (4→5 … 8→9):

```markdown
3a. **Messages (Anthropic-shape)** — ten sam silnik, endpoint `/v1/messages`:
   `curl -N http://<IP>:8080/v1/messages -H 'Content-Type: application/json' -d '{"model":"mlx:mlx-community/Qwen3-1.7B-4bit","messages":[{"role":"user","content":"Napisz wiersz o Wiśle"}],"stream":true}'`
   → eventy `message_start`/`content_block_start`/`ping`/`content_block_delta`…/`content_block_stop`/`message_delta`/`message_stop`; **brak** `[DONE]`.
   Bez strumienia (`stream:false`) → JSON `"type":"message"`, `content[0].text`, `stop_reason:"end_turn"`, `usage.input_tokens/output_tokens`.
   Zły id z prefiksem `mlx:` → 409 `model_not_ready` w envelope `{"type":"error",...}`.
```

- [ ] **Step 3: Full verification, once more**

Run:
```bash
PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit
PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat
```
Expected: ModelKit 22/22, OpenAICompat 63/63.

- [ ] **Step 4: Commit**

```bash
git add PocketServe/RUN_ON_IPHONE_PHASE2.md
git commit -m "docs: add /v1/messages step to device smoke runbook"
```

- [ ] **Step 5: Note for the human (device smoke, manual)**

Device re-smoke (phone awake + on LAN, IP may change — re-scan Bonjour `_oai._tcp.`): run §4 including the new 3a step. Record any deviations in `docs/KNOWN_ISSUES.md`.

---

## Self-review (authored with fresh eyes against the spec)

1. **Spec coverage:** non-stream JSON (§2 wire) → Task 2; streaming 7-event sequence → Task 2; no `[DONE]` → Tasks 1+2 asserts; error table (429/404/409/400/500/mid-stream) → Task 2 tests + `anthropicErrorType`; msg_ id → Task 2; tests 1–6 from spec §Testing → Tasks 1–2; runbook §4 addition → Task 3; simulator build → Task 3. No gaps.
2. **Placeholders:** none — every code step has full code; commands have expected output.
3. **Type consistency:** `AnthropicUsage(inputTokens:outputTokens:)`, `AnthropicMessageResponse(id:model:content:stopReason:usage:)`, `AnthropicErrorBody(errorType:message:)`, encoder static method names, `WireFormat`, `runInference(_:conn:wire:)` used identically in Tasks 1–3; MockEngine tokens `["To"," jest"," mock"]` match the joined `"To jest mock"` assertions (3 deltas).
