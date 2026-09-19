# PocketServe Phase 1: AFM OpenAI-Compatible Endpoint — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iPhone app `PocketServe` exposing an OpenAI-compatible HTTP endpoint backed by Apple's on-device AFM model, consumable from a MacBook over LAN Wi-Fi (curl first, GUI w Phase 3).

**Architecture:** lokalny pakiet SPM `OpenAICompat` (DTO, SSE, parser HTTP, `NWListener` serwer, routing) testowany jednostkowo + integracyjnie na macOS; minimalna apka iOS 27 (`PocketServe`) hostuje serwer i `AFMEngine` (FoundationModels), publikuje się przez Bonjour.

**Tech Stack:** Swift 6, SwiftPM, Network.framework (`NWListener`/`NWPublishInfo`), FoundationModels (iOS 26+), XCTest, SwiftUI (UI statusu), GRDB (dopiero Phase 3).

## Global Constraints

- Cel platformy: iOS 27 na iPhonie 18 Pro Max; testy SPM+iOS-kod compile run na macOS (Apple Silicon)
- Bez auth, plain HTTP, LAN-only (świadoma decyzja ze spec §3.6)
- Serwer on-demand: żyje tylko gdy apka iOS na froncie (`beginBackgroundTask` dokańcza trwający request)
- Single-flight: równoległy drugi `/v1/chat/completions` → `429`
- OpenAI error schema dla wszystkich błędów HTTP; nazwa pola modeli w `/v1/models`: `apple-afm`, mlx modele `mlx:<repo>` (faza 2)
- Swift 6 strict concurrency; brak `try?` przy parsowaniu protokołu; DRY; commit po każdym zielonym teście
- Nazwy API FoundationModels mogą się różnić w iOS 27 GA — potwierdzić autouzupełnianiem w Xcode 27 (punkt w Task 7, nie placeholder)

## File Structure

```
Packages/OpenAICompat/
  Package.swift
  Sources/OpenAICompat/
    Models.swift            # DTO OpenAI (request/response/chunk/error)
    SSE.swift             # SSEEncoder + inkrementalny SSEParser
    TokenCounter.swift    # aproksymacja tokenów
    ContextTruncator.swift
    PromptBuilder.swift   # messages -> plain prompt dla silników
    InferenceEngine.swift # protokół silnika + MockEngine
    RequestParser.swift   # czysta funkcja HTTP/1.1 parse
    HTTPServer.swift      # NWListener + routing + single-flight
  Tests/OpenAICompatTests/
    ModelsTests.swift
    SSETests.swift
    TokenCounterTests.swift
    ContextTruncatorTests.swift
    PromptBuilderTests.swift
    RequestParserTests.swift
    HTTPServerTests.swift
PocketServe/                 # Xcode project (Task 7, ręcznie)
  PocketServe/
    PocketServeApp.swift
    ServerModel.swift        # ObservableObject: serwer + Bonjour + AFM
    AFMEngine.swift          # adapter FoundationModels
    ContentView.swift
```

---

### Task 1: Scaffold pakietu SPM + DTO `ChatMessage`

**Files:**
- Create: `Packages/OpenAICompat/Package.swift`
- Create: `Packages/OpenAICompat/Sources/OpenAICompat/Models.swift`
- Create: `Packages/OpenAICompat/Tests/OpenAICompatTests/ModelsTests.swift`

**Interfaces:**
- Produces: `ChatMessage(role: String, content: String)` (Codable, Sendable); `Package.swift` target `OpenAICompat` + test target.

- [ ] **Step 1: Utwórz `Packages/OpenAICompat/Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenAICompat",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OpenAICompat", targets: ["OpenAICompat"])],
    targets: [
        .target(name: "OpenAICompat"),
        .testTarget(name: "OpenAICompatTests", dependencies: ["OpenAICompat"]),
    ]
)
```

- [ ] **Step 2: Napisz failing test `ModelsTests.swift`**

```swift
import XCTest
@testable import OpenAICompat

final class ModelsTests: XCTestCase {
    func testChatMessageRoundTrip() throws {
        let json = #"{"role":"user","content":"hej"}"#
        let msg = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg, ChatMessage(role: "user", content: "hej"))
        let back = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(msg))
        XCTAssertEqual(back, ["role": "user", "content": "hej"]) // kolejność kluczy JSONEncoder niezdefiniowana
    }
}
```

- [ ] **Step 3: Uruchom test, potwierdź fail**

Run: `swift test --package-path Packages/OpenAICompat --filter ModelsTests 2>&1 | tail -5`
Expected: FAIL / błąd kompilacji `cannot find 'ChatMessage' in scope`

- [ ] **Step 4: Zaimplementuj minimum w `Models.swift`**

```swift
import Foundation

public struct ChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}
```

- [ ] **Step 5: Test przechodzi**

Run: `swift test --package-path Packages/OpenAICompat --filter ModelsTests`
Expected: `Test Suite 'ModelsTests' passed`

- [ ] **Step 6: Commit**

```bash
git add Packages
git commit -m "feat(spm): scaffold OpenAICompat package with ChatMessage DTO"
```

---

### Task 2: Pełne DTO (request / response / chunk / error) + `PromptBuilder`

**Files:**
- Modify: `Packages/OpenAICompat/Sources/OpenAICompat/Models.swift`
- Create: `Packages/OpenAICompat/Sources/OpenAICompat/PromptBuilder.swift`
- Create: `Packages/OpenAICompat/Tests/OpenAICompatTests/PromptBuilderTests.swift`
- Modify: `Packages/OpenAICompat/Tests/OpenAICompatTests/ModelsTests.swift`

**Interfaces:**
- Consumes: `ChatMessage` (Task 1).
- Produces: `ChatCompletionRequest(model, messages, stream, temperature, maxTokens)`; `ChatCompletionChunk(id, created, model, choices:[ChunkChoice(delta, finishReason)])`; `Delta(content: String?)`; `ResponseChoice(index, message: ChatMessage, finishReason)`; `CompletionResponse(choices:[ResponseChoice], usage)`; `OpenAIErrorBody(message, type)`; `Usage(promptTokens, completionTokens)`; `PromptBuilder.prompt(from:) -> String`; `ModelInfo(id, contextWindow)`; `ModelsList(data:[ModelInfo])`; `GenerationParams(temperature, maxTokens)`.

- [ ] **Step 1: Dopisz failing testy do `ModelsTests.swift`**

```swift
    func testRequestDecodesSnakeCaseDefaults() throws {
        let json = #"{"model":"apple-afm","messages":[{"role":"user","content":"hi"}]}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(req.model, "apple-afm")
        XCTAssertFalse(req.stream)
        XCTAssertEqual(req.temperature, 0.7, accuracy: 0.001)
    }
    func testChunkEncodesOpenAIShape() throws {
        let c = ChatCompletionChunk(id: "chatcmpl-1", created: 2, model: "apple-afm",
            choices: [.init(index: 0, delta: .init(content: "x"), finishReason: nil)])
        let d = (try? JSONEncoder().encode(c)).flatMap { String(data: $0, encoding: .utf8) }!
        XCTAssertTrue(d.contains("\"object\":\"chat.completion.chunk\""))
        XCTAssertTrue(d.contains("\"finish_reason\":null"))
    }
    func testErrorBodyShape() throws {
        let e = OpenAIErrorBody(message: "nope", type: "invalid_request_error")
        let d = (try? JSONEncoder().encode(e)).flatMap { String(data: $0, encoding: .utf8) }!
        XCTAssertTrue(d.contains(#""error":{""#))
    }
```

- [ ] **Step 2: Uruchom, potwierdź compile fail**

Run: `swift test --package-path Packages/OpenAICompat --filter ModelsTests 2>&1 | tail -5`
Expected: FAIL `cannot find 'ChatCompletionRequest' in scope`

- [ ] **Step 3: Implementacja DTO w `Models.swift`**

```swift
public struct ChatCompletionRequest: Codable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let stream: Bool
    public let temperature: Double
    public let maxTokens: Int
    public init(model: String, messages: [ChatMessage], stream: Bool = false,
                temperature: Double = 0.7, maxTokens: Int = 512) {
        self.model = model; self.messages = messages; self.stream = stream
        self.temperature = temperature; self.maxTokens = maxTokens
    }
    enum CodingKeys: String, CodingKey { case model, messages, stream, temperature
        case maxTokens = "max_tokens" }
}

public struct Delta: Codable, Sendable, Equatable { public let content: String?
    public init(content: String?) { self.content = content } }

public struct ChunkChoice: Codable, Sendable { public let index: Int
    public let delta: Delta
    public let finishReason: String?
    public init(index: Int, delta: Delta, finishReason: String?) {
        self.index = index; self.delta = delta; self.finishReason = finishReason }
    enum CodingKeys: String, CodingKey { case index, delta
        case finishReason = "finish_reason" } }

public struct ChatCompletionChunk: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [ChunkChoice]
    public init(id: String, created: Int, model: String, choices: [ChunkChoice]) {
        self.id = id; self.object = "chat.completion.chunk"; self.created = created
        self.model = model; self.choices = choices } }

public struct Usage: Codable, Sendable { public let promptTokens: Int
    public let completionTokens: Int
    enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens" }
    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens } }

public struct ResponseChoice: Codable, Sendable { public let index: Int
    public let message: ChatMessage
    public let finishReason: String?
    public init(index: Int, message: ChatMessage, finishReason: String?) {
        self.index = index; self.message = message; self.finishReason = finishReason }
    enum CodingKeys: String, CodingKey { case index, message
        case finishReason = "finish_reason" } }

public struct CompletionResponse: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [ResponseChoice]
    public let usage: Usage
    public init(id: String, created: Int, model: String, choices: [ResponseChoice], usage: Usage) {
        self.id = id; self.object = "chat.completion"; self.created = created
        self.model = model; self.choices = choices; self.usage = usage } }

public struct OpenAIErrorBody: Codable, Sendable { public let error: ErrorDetail
    public struct ErrorDetail: Codable, Sendable { public let message: String; public let type: String }
    public init(message: String, type: String) { error = ErrorDetail(message: message, type: type) } }

public struct ModelInfo: Codable, Sendable, Equatable { public let id: String
    public let object: String
    public let created: Int
    public let contextWindow: Int
    public init(id: String, created: Int, contextWindow: Int) {
        self.id = id; self.object = "model"; self.created = created
        self.contextWindow = contextWindow }
    enum CodingKeys: String, CodingKey { case id, object, created
        case contextWindow = "context_window" } }

public struct ModelsList: Codable, Sendable { public let object: String
    public let data: [ModelInfo]
    public init(data: [ModelInfo]) { self.object = "list"; self.data = data } }

public struct GenerationParams: Sendable, Equatable { public let temperature: Double
    public let maxTokens: Int
    public init(temperature: Double, maxTokens: Int) {
        self.temperature = temperature; self.maxTokens = maxTokens } }
```

- [ ] **Step 4: Failing `PromptBuilderTests.swift`**

```swift
import XCTest
@testable import OpenAICompat

final class PromptBuilderTests: XCTestCase {
    func testSerializesRoles() {
        let p = PromptBuilder.prompt(from: [
            ChatMessage(role: "system", content: "jesteś asystentem"),
            ChatMessage(role: "user", content: "cześć")])
        XCTAssertEqual(p, "<|system|>\njesteś asystentem\n<|user|>\ncześć\n")
    }
}
```

- [ ] **Step 5: Implementacja `PromptBuilder.swift`**

```swift
public enum PromptBuilder {
    public static func prompt(from messages: [ChatMessage]) -> String {
        messages.map { "<|\($0.role)|>\n\($0.content)\n" }.joined()
    }
}
```

- [ ] **Step 6: `swift test --package-path Packages/OpenAICompat` → PASS (wszystkie)**
- [ ] **Step 7: Commit** `git add Packages && git commit -m "feat(spm): full OpenAI DTOs + prompt builder"`

---

### Task 3: `SSEEncoder` + inkrementalny `SSEParser`

**Interfaces:**
- Consumes: `ChatCompletionChunk`.
- Produces: `SSEEncoder.encode(_ chunk) -> Data`, `SSEEncoder.done -> Data`, `SSEParser.feed(Data) -> [String]` (payloady linii `data:`, pomija `[DONE]` i komentarze).

- [ ] **Step 1: Failing `SSETests.swift`**

```swift
import XCTest
@testable import OpenAICompat

final class SSETests: XCTestCase {
    func testEncodeChunkHasBlankLineTerminator() throws {
        let c = ChatCompletionChunk(id: "a", created: 1, model: "m",
            choices: [.init(index: 0, delta: .init(content: "x"), finishReason: nil)])
        let d = try SSEEncoder.encode(c)
        XCTAssertEqual(String(data: d, encoding: .utf8)!.suffix(2), "\n\n")
    }
    func testDoneSentinel() { XCTAssertEqual(String(data: SSEEncoder.done, encoding: .utf8), "data: [DONE]\n\n") }
    func testParserHandlesSplitAcrossFeeds() {
        var p = SSEParser()
        let full = "data: {\"x\":1}\n\ndata: [DONE]\n\n"
        var out: [String] = []
        for b in full.utf8 { out += p.feed(Data([b])) }
        XCTAssertEqual(out, ["{\"x\":1}"])
    }
    func testParserIgnoresComments() {
        var p = SSEParser()
        XCTAssertEqual(p.feed(Data(": keep-alive\n\n".utf8)), [])
    }
}
```

- [ ] **Step 2: `swift test ... --filter SSETests` → compile FAIL (oczekiwane)**
- [ ] **Step 3: Implementacja `SSE.swift`**

```swift
public enum SSEEncoder {
    public static let done = Data("data: [DONE]\n\n".utf8)
    public static func encode(_ chunk: ChatCompletionChunk) throws -> Data {
        var json = try JSONEncoder().encode(chunk)
        var out = Data("data: ".utf8); out.append(json); out.append("\n\n".data(using: .utf8)!)
        return out
    }
}

public struct SSEParser {
    private var buffer = ""
    public init() {}
    public mutating func feed(_ data: Data) -> [String] {
        buffer += String(decoding: data, as: UTF8.self)
        var events: [String] = []
        while let range = buffer.range(of: "\n\n") {
            let event = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            for line in event.components(separatedBy: "\n") where line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                if payload != "[DONE"] { events.append(payload) }
            }
        }
        return events
    }
}
```

- [ ] **Step 4: `swift test --package-path Packages/OpenAICompat` → PASS**
- [ ] **Step 5: Commit** `git commit -am "feat(spm): SSE encode/parse round-trip"`

---

### Task 4: `TokenCounter` + `ContextTruncator`

**Interfaces:**
- Produces: `TokenCounter.approximate(_ String) -> Int`; `ContextTruncator.truncate(messages:[ChatMessage], budgetTokens:Int) -> (kept:[ChatMessage], droppedTokens:Int)` — zachowuje `system`, tnie najstarsze `user/assistant`.

- [ ] **Step 1: Failing testy `TokenCounterTests.swift` + `ContextTruncatorTests.swift`**

```swift
final class TokenCounterTests: XCTestCase {
    func testApproxOneTokenPerFourChars() {
        XCTAssertEqual(TokenCounter.approximate("1234567890"), 2)
        XCTAssertGreaterThanOrEqual(TokenCounter.approximate("a"), 1)
    }
}
final class ContextTruncatorTests: XCTestCase {
    func testKeepsSystemAndNewestWithinBudget() {
        let sys = ChatMessage(role: "system", content: "AAA")          // ~1 tok
        let old = ChatMessage(role: "user", content: String(repeating: "x", count: 400)) // 100 tok
        let new = ChatMessage(role: "user", content: "ok")
        let r = ContextTruncator.truncate(messages: [sys, old, new], budgetTokens: 50)
        XCTAssertEqual(r.kept.map(\.role), ["system", "user"])
        XCTAssertEqual(r.kept.last?.content, "ok")
        XCTAssertGreaterThan(r.droppedTokens, 50)
    }
    func testBudgetCoversAllKeepsAll() {
        let ms = [ChatMessage(role: "user", content: "a"), ChatMessage(role: "assistant", content: "b")]
        XCTAssertEqual(ContextTruncator.truncate(messages: ms, budgetTokens: 1000).kept.count, 2)
    }
}
```

- [ ] **Step 2: Potwierdź compile FAIL**
- [ ] **Step 3: Implementacja `TokenCounter.swift` i `ContextTruncator.swift`**

```swift
public enum TokenCounter {
    public static func approximate(_ text: String) -> Int { max(1, text.count / 4) }
    public static func approximate(_ message: ChatMessage) -> Int {
        approximate(message.role) + approximate(message.content) + 4 // framing <|role|>
    }
}

public enum ContextTruncator {
    public static func truncate(messages: [ChatMessage], budgetTokens: Int)
        -> (kept: [ChatMessage], droppedTokens: Int) {
        var system = messages.filter { $0.role == "system" }
        let rest = messages.filter { $0.role != "system" }
        let sysCost = system.reduce(0) { $0 + TokenCounter.approximate($1) }
        var kept: [ChatMessage] = []
        var dropped = 0
        var cost = sysCost
        for m in rest.reversed() {
            let c = TokenCounter.approximate(m)
            if cost + c <= budgetTokens { cost += c; kept.insert(m, at: 0) }
            else { dropped += c }
        }
        system.append(contentsOf: kept)
        return (system, dropped)
    }
}
```

- [ ] **Step 4: `swift test` → PASS; commit** `"feat(spm): token counter + context truncation"`

---

### Task 5: `InferenceEngine` + `MockEngine` + `RequestParser`

**Interfaces:**
- Produces: `protocol InferenceEngine: Sendable { var id: String { get }; var contextWindow: Int { get }; func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> }`; `MockEngine(tokens:[String], latency: Duration)`; `RequestParser.parse(Data) -> HTTPRequest?`; `HTTPRequest(method, path, headers:[String:String], body:Data)` (nagłówki znormalizowane lowercase).

- [ ] **Step 1: Failing `RequestParserTests.swift`**

```swift
final class RequestParserTests: XCTestCase {
    func testParsesGetWithoutBody() {
        let raw = "GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n"
        let r = RequestParser.parse(Data(raw.utf8))!
        XCTAssertEqual(r.method, "GET"); XCTAssertEqual(r.path, "/v1/models")
        XCTAssertEqual(r.headers["host"], "x"); XCTAssertEqual(r.body.count, 0)
    }
    func testIncompleteReturnsNil() {
        XCTAssertNil(RequestParser.parse(Data("POST /v1/chat HTTP/1.1\r\nContent-Length: 5\r\n\r".utf8)))
    }
    func testWaitsForFullBody() {
        var r: HTTPRequest?
        for b in "POST /v1/chat HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8 { r = RequestParser.parse(Data(String(UnicodeScalar(b)).utf8)) }
        XCTAssertEqual(r?.body, Data("{}".utf8))
    }
}
```

- [ ] **Step 2: Potwierdź FAIL**
- [ ] **Step 3: `RequestParser.swift` + `InferenceEngine.swift`**

```swift
public struct HTTPRequest: Sendable {
    public let method: String; public let path: String
    public let headers: [String: String]; public let body: Data
}

public enum RequestParser {
    public static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = buffer[buffer.startIndex..<sep.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        }
        let need = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[sep.upperBound...]
        guard body.count >= need else { return nil }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                           headers: headers, body: Data(body.prefix(need)))
    }
}

import Foundation
public protocol InferenceEngine: Sendable {
    var id: String { get }
    var contextWindow: Int { get }
    func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error>
}

public actor MockEngine: InferenceEngine {
    public nonisolated let id: String
    public nonisolated let contextWindow: Int
    private let tokens: [String]
    public init(id: String = "mock", contextWindow: Int = 4096,
                tokens: [String] = ["To", " jest", " mock"], latency: Duration = .zero) {
        self.id = id; self.contextWindow = contextWindow; self.tokens = tokens; self.latency = latency
    }
    private let latency: Duration
    public func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> {
        let tokens = self.tokens; let latency = self.latency
        return AsyncThrowingStream { c in
            Task {
                for t in tokens where !Task.isCancelled {
                    if latency != .zero { try? await Task.sleep(for: latency) }
                    c.yield(t)
                }
                c.finish()
            }
        }
    }
}
```

- [ ] **Step 4: `swift test` → PASS; commit** `"feat(spm): request parser + engine protocol"`

---

### Task 6: `HTTPServer` (`NWListener`) — routing + single-flight + streaming

**Files:**
- Create: `Packages/OpenAICompat/Sources/OpenAICompat/HTTPServer.swift`
- Create: `Packages/OpenAICompat/Tests/OpenAICompatTests/HTTPServerTests.swift`

**Interfaces:**
- Consumes: `RequestParser`, `InferenceEngine`, `SSEEncoder`, `PromptBuilder`, DTO.
- Produces: `actor HTTPServer { init(engines: [any InferenceEngine]); func start(port: UInt16) async throws -> UInt16 /* faktyczny port*/; func stop(); var port: UInt16? }` — route: `GET /v1/models`, `POST /v1/chat/completions`; błędy: 400/404/429/409 w `OpenAIErrorBody`.

- [ ] **Step 1: Failing `HTTPServerTests.swift`**

```swift
import XCTest
@testable import OpenAICompat

final class HTTPServerTests: XCTestCase {
    func makeServer() -> HTTPServer { HTTPServer(engines: [MockEngine()]) }

    func testModelsListsEngine() async throws {
        let s = makeServer(); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let list = try JSONDecoder().decode(ModelsList.self, from: data)
        XCTAssertEqual(list.data.map(\.id), ["mock"])
    }
    func testChatNonStreamingJSON() async throws {
        let s = makeServer(); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ChatCompletionRequest(model: "mock", messages: [ChatMessage(role: "user", content: "siema")]))
        let (data, _) = try await URLSession.shared.data(for: req)
        let r = try JSONDecoder().decode(CompletionResponse.self, from: data)
        XCTAssertEqual(r.choices.first?.message.content, "To jest mock")
    }
    func testChatStreamSSEDone() async throws {
        let s = makeServer(); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ChatCompletionRequest(model: "mock", messages: [ChatMessage(role: "user", content: "x")], stream: true))
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        var parser = SSEParser(); var text = ""
        for try await line in bytes.lines { text += parser.feed(Data((line + "\n").utf8)).joined() }
        text += parser.feed(Data("\n"))
        XCTAssertEqual(text, "To jest mock")
    }
    func testUnknownModel404() async throws {
        let s = makeServer(); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"; req.httpBody = try JSONEncoder().encode(ChatCompletionRequest(model: "ghost", messages: []))
        let (data, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("model_not_found"))
    }
}
```

- [ ] **Step 2: Potwierdź FAIL (`cannot find HTTPServer`)**
- [ ] **Step 3: Implementacja `HTTPServer.swift`**

```swift
import Foundation
import Network

public actor HTTPServer {
    private let engines: [String: any InferenceEngine]
    private var listener: NWListener?
    private var busy = false
    public private(set) var port: UInt16?

    public init(engines: [any InferenceEngine]) {
        self.engines = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
    }

    public func start(port: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        self.listener = listener
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [weak listener] state in
                if case .ready(let endpoint) = state, let p = endpoint.port {
                    cont.resume(returning: p)
                } else if case .failed(let e) = state { cont.resume(throwing: e) }
            }
            listener.newConnectionHandler = { [self] conn in Task { await self.handle(conn) } }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    public func stop() { listener?.cancel(); listener = nil; port = nil }

    // MARK: - per connection

    private nonisolated func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        receive(conn, Data())
    }

    private nonisolated func receive(_ conn: NWConnection, _ acc: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            var buf = acc
            if let data { buf.append(data) }
            guard error == nil else { conn.cancel(); return }
            guard let request = RequestParser.parse(buf) else {
                if complete { conn.cancel() } else { self.receive(conn, buf) }
                return
            }
            Task { await self.route(request, conn) }
        }
    }

    private func route(_ req: HTTPRequest, _ conn: NWConnection) async {
        if req.method == "GET", req.path == "/v1/models" {
            let list = ModelsList(data: engines.values
                .sorted { $0.id < $1.id }
                .map { ModelInfo(id: $0.id, created: 0, contextWindow: $0.contextWindow) })
            sendJSON(conn, 200, try! JSONEncoder().encode(list)); return
        }
        guard req.method == "POST", req.path == "/v1/chat/completions" else {
            sendError(conn, 404, "not_found"); return
        }
        guard !busy else { sendError(conn, 429, "server_busy"); return }
        let request: ChatCompletionRequest
        do { request = try JSONDecoder().decode(ChatCompletionRequest.self, from: req.body) }
        catch { sendError(conn, 400, "invalid_request_error"); return }
        guard let engine = engines[request.model] else {
            sendError(conn, 404, "model_not_found"); return
        }
        busy = true
        defer { busy = false }
        let prompt = PromptBuilder.prompt(from: request.messages)
        let params = GenerationParams(temperature: request.temperature, maxTokens: request.maxTokens)
        let id = "chatcmpl-\(UUID().uuidString.prefix(8))"
        let created = Int(Date().timeIntervalSince1970)
        if request.stream {
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n".utf8)
            conn.send(content: header, contentContext: .head, isComplete: false, completion: .content)
            var completionTokens = 0
            do {
                for try await token in engine.stream(prompt: prompt, params: params) {
                    completionTokens += max(1, token.count / 4)
                    let chunk = ChatCompletionChunk(id: id, created: created, model: request.model,
                        choices: [.init(index: 0, delta: .init(content: token), finishReason: nil)])
                    conn.send(content: try SSEEncoder.encode(chunk), contentContext: .message, isComplete: false, completion: .content)
                }
                let end = ChatCompletionChunk(id: id, created: created, model: request.model,
                    choices: [.init(index: 0, delta: .init(content: nil), finishReason: "stop")])
                conn.send(content: try SSEEncoder.encode(end), contentContext: .message, isComplete: false, completion: .content)
                conn.send(content: SSEEncoder.done, contentContext: .message, isComplete: true, completion: .content_cancelled)
            } catch {
                conn.cancel()
            }
        } else {
            var full = ""
            do { for try await t in engine.stream(prompt: prompt, params: params) { full += t } }
            catch { sendError(conn, 500, "server_error"); return }
            let usage = Usage(promptTokens: TokenCounter.approximate(prompt),
                              completionTokens: TokenCounter.approximate(full))
            let resp = CompletionResponse(id: id, created: created, model: request.model,
                choices: [.init(index: 0, message: ChatMessage(role: "assistant", content: full), finishReason: "stop")], usage: usage)
            sendJSON(conn, 200, try! JSONEncoder().encode(resp))
        }
    }

    private func sendJSON(_ conn: NWConnection, _ status: Int, _ body: Data) {
        let h = "HTTP/1.1 \(status) \r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(h.utf8) + body, contentContext: .completeMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendError(_ conn: NWConnection, _ status: Int, _ type: String) {
        sendJSON(conn, status, try! JSONEncoder().encode(OpenAIErrorBody(message: type, type: type)))
    }
}
```

- [ ] **Step 4: `swift test --package-path Packages/OpenAICompat` → PASS (4 testy serwera)**
      (pierwsze uruchomienie może poprosić o zgodę macOS "Local Network" dla toolchaina — zatwierdź)
- [ ] **Step 5: Full suite PASS + commit** `"feat(spm): NWListener HTTP server with streaming + errors"`

---

### Task 7: Apka iOS `PocketServe` + Bonjour + AFM + smoke na urządzeniu

**Files (ręcznie w Xcode 27, potem add do gita):**
- Create: `PocketServe/` Xcode project (iOS App, SwiftUI, min iOS 27, bundle `com.pawel.pocketserve`), lokalny dependency: `Packages/OpenAICompat`
- Create: `PocketServe/PocketServe/AFMEngine.swift`, `ServerModel.swift`, `ContentView.swift` (edycja szablonu)
- Modify: `PocketServe/PocketServe/Info.plist`

**Interfaces:**
- Consumes: `HTTPServer(engines:)`, `InferenceEngine` (Task 5/6), `NetService` (Bonjour).
- Produces: uruchomiony serwer na porcie 8080 na iPhonie; `apple-afm` w `/v1/models`; `NetService` `_oai._tcp` opublikowany.

- [ ] **Step 1: Utwórz projekt:** Xcode → New Project → iOS App, product name `PocketServe`, Interface SwiftUI, min deployment iOS 27. Dodaj lokalny pakiet: File → Add Package Dependencies → Add Local… → wybierz `Packages/OpenAICompat`.
- [ ] **Step 2: `Info.plist` — dodaj klucze** (bez nich Network zablokuje serwer):

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Serwer AI dla Twojego komputera</string>
<key>NSBonjourServices</key>
<array><string>_oai._tcp</string></array>
```

- [ ] **Step 3: `AFMEngine.swift`** — zweryfikuj sygnatury `streamResponse(to:)` headerami Xcode 27 (Global Constraint); szablon oparty na API iOS 26 FoundationModels:

```swift
import FoundationModels
import OpenAICompat

@available(iOS 26, *)
final class AFMEngine: InferenceEngine, @unchecked Sendable {
    let id = "apple-afm"
    var contextWindow: Int { 4096 } // potwierdź capabilities AFM 3B w iOS 27
    func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard SystemLanguageModel.default.availability == .available else {
                        throw NSError(domain: "afm", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence wyłączony"])
                    }
                    let session = LanguageModelSession()
                    let options = GenerationOptions(excludedInstructions: [])
                    for try await fragment in session.streamResponse(to: prompt, options: options) {
                        continuation.yield(fragment)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: `ServerModel.swift`**

```swift
import Foundation
import OpenAICompat
import SwiftUI

@MainActor final class ServerModel: ObservableObject {
    @Published var running = false
    @Published var port: UInt16 = 8080
    private let server = HTTPServer(engines: [AFMEngine()])
    private var netService: NetService?

    func start() {
        Task { do { port = try await server.start(port: 8080); running = true; publishBonjour() } }
    }
    func stop() { netService?.stop(); Task { await server.stop() }; running = false }
    private func publishBonjour() {
        let name = ProcessInfo.processInfo.hostName.components(separatedBy: ".local").first ?? "pocketserve"
        let svc = NetService(domain: "local.", type: "_oai._tcp.", name: name, port: Int(port))
        svc.delegate = self
        netService = svc
        svc.publish()
    }
}

extension ServerModel: NetServiceDelegate {
    nonisolated func netServiceDidPublish(_ sender: NetService) {} // klient macOS: NWBrowser("_oai._tcp.") w Phase 3
}
```
Bonjour publikowany przez stabilny `NetService` (Foundation); klient fazy 3 użyje `NWBrowser` na tym samym typie serwisu.

- [ ] **Step 5: `ContentView.swift`**

```swift
import SwiftUI
struct ContentView: View {
    @StateObject private var model = ServerModel()
    var body: some View {
        VStack(spacing: 20) {
            Text("PocketServe").font(.largeTitle)
            Text(model.running ? "● online :\(model.port)" : "○ offline")
                .foregroundStyle(model.running ? .green : .secondary)
            Button(model.running ? "Stop" : "Start") { model.running ? model.stop() : model.start() }
                .buttonStyle(.borderedProminent)
            if model.running { Text("\(UIDevice.current.name).local:8080").font(.system(.body, design: .monospaced)) }
        }.padding()
    }
}
```

- [ ] **Step 6: Run na iPhone 18 Pro Max** → Start → potwierdź z terminala Maca:

```bash
curl http://<iphone-ip>:8080/v1/models        # → {"object":"list","data":[{"id":"apple-afm",...}]}
curl -N -X POST http://<iphone-ip>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"apple-afm","messages":[{"role":"user","content":"Podaj 3 fakty o Marsie"}],"stream":true}'
```
Expected: tokeny SSE płynące ~40 tok/s; brak blokad sandbox (grant Local Network przy pierwszym starcie).
- [ ] **Step 7: Background-task guard:** w `ScenePhase` `.background` → `UIApplication.beginBackgroundTask` nieprzekraczalnie do zakończenia trwającego stream, bez restartu żądań.
- [ ] **Step 8: Commit** `"feat(ios): PocketServe hosting AFM endpoint + bonjour"`

---

## Definition of Done (Phase 1)

- `swift test` w `Packages/OpenAICompat`: 100% zielone
- curl z Maca: `/v1/models` + streaming `apple-afm` działa na iPhonie przez LAN
- Zamknięcie apki iOS = endpoint pada (feature), restart przez UI
- Spec coverage: §4 architektura ✅ §5 flow ✅ §6 błędy 400/404/429 ✅; MLX/HF download → Phase 2; Companion GUI → Phase 3
