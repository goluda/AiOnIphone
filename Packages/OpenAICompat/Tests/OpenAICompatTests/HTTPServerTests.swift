import XCTest
import Network
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
        for try await line in bytes.lines { text += try deltaText(parser.feed(Data((line + "\n").utf8))) }
        text += try deltaText(parser.feed(Data("\n".utf8)))
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

    func testUnknownPath404() async throws {
        let s = makeServer(); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let (_, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/nope")!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 404)
    }
    func testInvalidJSONBody400() async throws {
        let s = makeServer(); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"; req.httpBody = Data("not json".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("invalid_request_error"))
    }
    func testSecondConcurrentChatGets429AndBusyReleases() async throws {
        let s = HTTPServer(engines: [MockEngine(latency: .milliseconds(150))])
        let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let streamBody = try JSONEncoder().encode(ChatCompletionRequest(model: "mock", messages: [ChatMessage(role: "user", content: "x")], stream: true))
        let a = try await rawConnect(port: port); defer { a.cancel() }
        a.send(content: rawPOST(path: "/v1/chat/completions", body: streamBody), completion: .contentProcessed { _ in })
        let head = try await rawReceive(a)
        XCTAssertTrue(String(data: head, encoding: .utf8)!.hasPrefix("HTTP/1.1 200")) // SSE head arrived => busy acquired

        var reqB = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        reqB.httpMethod = "POST"; reqB.setValue("application/json", forHTTPHeaderField: "Content-Type")
        reqB.httpBody = try JSONEncoder().encode(ChatCompletionRequest(model: "mock", messages: [ChatMessage(role: "user", content: "second")]))
        let (dataB, respB) = try await URLSession.shared.data(for: reqB)
        XCTAssertEqual((respB as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertTrue(String(data: dataB, encoding: .utf8)!.contains("server_busy"))

        let (_, respM) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        XCTAssertEqual((respM as? HTTPURLResponse)?.statusCode, 200) // models not gated

        let all = try await receiveAll(a)
        XCTAssertTrue(String(data: all, encoding: .utf8)!.contains("[DONE]"))
        var parser = SSEParser()
        XCTAssertEqual(try deltaText(parser.feed(head)) + deltaText(parser.feed(all)), "To jest mock")

        let (dataC, respC) = try await URLSession.shared.data(for: reqB) // busy released after drain
        XCTAssertEqual((respC as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(CompletionResponse.self, from: dataC).choices.first?.message.content, "To jest mock")
    }
    func testHealthReturns200() async throws {
        let s = makeServer(); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"status\":\"ok\"}")
    }
    func testHealth200WhileChatInFlight() async throws {
        let s = HTTPServer(engines: [MockEngine(latency: .milliseconds(150))])
        let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let streamBody = try JSONEncoder().encode(ChatCompletionRequest(model: "mock", messages: [ChatMessage(role: "user", content: "x")], stream: true))
        let a = try await rawConnect(port: port); defer { a.cancel() }
        a.send(content: rawPOST(path: "/v1/chat/completions", body: streamBody), completion: .contentProcessed { _ in })
        let head = try await rawReceive(a)
        XCTAssertTrue(String(data: head, encoding: .utf8)!.hasPrefix("HTTP/1.1 200")) // SSE head arrived => busy acquired
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200) // health ungated while busy
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"status\":\"ok\"}")
        _ = try await receiveAll(a) // drain stream
    }
    func testMalformedContentLengthRejected400() async throws {
        let s = makeServer(); let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let conn = try await rawConnect(port: port); defer { conn.cancel() }
        conn.send(content: Data("POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: banana\r\n\r\n{}".utf8), completion: .contentProcessed { _ in })
        let resp = try await receiveAll(conn)
        let text = String(data: resp, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(text.contains("invalid_request_error"))
    }
    func testServerSideClampTruncatesAndCapsMaxTokens() async throws {
        let spy = SpyEngine(id: "spy", contextWindow: 64)
        let s = HTTPServer(engines: [spy])
        let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let huge = String(repeating: "abcdefghij", count: 40) // 400 chars per message
        let msgs = [ChatMessage(role: "system", content: "rules")] +
            (1...8).map { ChatMessage(role: "user", content: "\($0)-\(huge)") }
        let body = try JSONEncoder().encode(ChatCompletionRequest(
            model: "spy",
            messages: msgs,
            maxTokens: 99999))
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(CompletionResponse.self, from: data).choices.first?.message.content, "ok")
        let captured = await spy.captured()
        XCTAssertEqual(captured.params.maxTokens, 64) // clamp do limitu modelu
        let unbuilt = PromptBuilder.prompt(from: msgs)
        XCTAssertLessThan(captured.prompt.count, unbuilt.count) // truncate przed inferencją
        XCTAssertFalse(captured.prompt.isEmpty) // system message ocala
    }
    func testClientDisconnectMidStreamKeepsServerUp() async throws {
        let s = HTTPServer(engines: [MockEngine(latency: .milliseconds(120))])
        let port = try await s.start(port: 0); defer { Task { await s.stop() } }
        let body = try JSONEncoder().encode(ChatCompletionRequest(model: "mock", messages: [ChatMessage(role: "user", content: "x")], stream: true))
        let a = try await rawConnect(port: port)
        a.send(content: rawPOST(path: "/v1/chat/completions", body: body), completion: .contentProcessed { _ in })
        _ = try await rawReceive(a) // stream started
        a.cancel() // disconnect mid-flight
        let deadline = Date().addingTimeInterval(15) // server alive; 429 while draining dead stream, then 200 once freed
        while Date() < deadline {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            req.httpMethod = "POST"; req.httpBody = try JSONEncoder().encode(ChatCompletionRequest(model: "mock", messages: [ChatMessage(role: "user", content: "y")]))
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                XCTAssertEqual(try JSONDecoder().decode(CompletionResponse.self, from: data).choices.first?.message.content, "To jest mock")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("server did not recover after mid-stream disconnect")
    }
}

private func deltaText(_ payloads: [String]) throws -> String {
    var out = ""
    for p in payloads { out += (try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(p.utf8)).choices.first?.delta.content) ?? "" }
    return out
}

private struct TestTimeout: Error {}

actor SpyEngine: InferenceEngine {
    let id: String
    let contextWindow: Int
    private var lastPrompt: String?
    private var lastParams: GenerationParams?
    init(id: String, contextWindow: Int) { self.id = id; self.contextWindow = contextWindow }
    func captured() -> (prompt: String, params: GenerationParams) { (lastPrompt ?? "", lastParams ?? GenerationParams(temperature: -1, maxTokens: -1)) }
    nonisolated func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> {
        let actor = self
        return AsyncThrowingStream { c in
            Task {
                await actor.record(prompt: prompt, params: params)
                for t in ["ok"] where !Task.isCancelled { c.yield(t) }
                c.finish()
            }
        }
    }
    private func record(prompt: String, params: GenerationParams) { lastPrompt = prompt; lastParams = params }
}


private func withTimeout<T: Sendable>(_ seconds: Double = 10,
                                       _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeout()
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func rawConnect(port: UInt16) async throws -> NWConnection {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TestTimeout() }
    let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
    conn.start(queue: DispatchQueue(label: "raw-client"))
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
    do {
        while true { out.append(try await rawReceive(conn)) }
    } catch { return out }
}
