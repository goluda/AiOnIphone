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
