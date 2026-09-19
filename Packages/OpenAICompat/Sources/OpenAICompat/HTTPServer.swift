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
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        self.listener = listener
        let resolved = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, any Error>) in
            let gate = StartGate(cont) // resume-once guard: .failed after .ready must not double-resume
            listener.stateUpdateHandler = { (state: NWListener.State) in
                switch state {
                case .ready: if let p = listener.port { gate.resume(.success(p.rawValue)) }
                case .failed(let e): gate.resume(.failure(e))
                default: break
                }
            }
            listener.newConnectionHandler = { [self] conn in
                Task { self.handle(conn) }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        self.port = resolved
        return resolved
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
        if let cl = req.headers["content-length"], Int(cl) == nil {
            sendError(conn, 400, "invalid_request_error"); return
        }
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
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8)
            conn.send(content: header, completion: .contentProcessed { _ in })
            do {
                for try await token in engine.stream(prompt: prompt, params: params) {
                    let chunk = ChatCompletionChunk(id: id, created: created, model: request.model,
                        choices: [.init(index: 0, delta: .init(content: token), finishReason: nil)])
                    conn.send(content: try SSEEncoder.encode(chunk), completion: .contentProcessed { _ in })
                }
                let end = ChatCompletionChunk(id: id, created: created, model: request.model,
                    choices: [.init(index: 0, delta: .init(content: nil), finishReason: "stop")])
                conn.send(content: try SSEEncoder.encode(end), completion: .contentProcessed { _ in })
                conn.send(content: SSEEncoder.done, completion: .contentProcessed { _ in conn.cancel() })
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
        conn.send(content: Data(h.utf8) + body, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendError(_ conn: NWConnection, _ status: Int, _ type: String) {
        sendJSON(conn, status, try! JSONEncoder().encode(OpenAIErrorBody(message: type, type: type)))
    }
}

private final class StartGate: @unchecked Sendable {
    private var cont: CheckedContinuation<UInt16, any Error>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<UInt16, any Error>) { self.cont = cont }
    func resume(_ result: Result<UInt16, any Error>) {
        lock.lock(); defer { lock.unlock() }
        guard let cont else { return }
        self.cont = nil
        cont.resume(with: result)
    }
}
