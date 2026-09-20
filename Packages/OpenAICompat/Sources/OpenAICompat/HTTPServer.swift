import Foundation
import Network

public actor HTTPServer {
    private let engines: [any InferenceEngine]
    private var ext: ServerExtension?
    private var listener: NWListener?
    private var busy = false
    public private(set) var port: UInt16?

    public init(engines: [any InferenceEngine], extension ext: ServerExtension? = nil) {
        self.engines = engines
        self.ext = ext
    }

    public func setExtension(_ ext: ServerExtension?) { self.ext = ext } // montaż /x/* bez restartu nasłuchu

    public func start(port: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        self.listener = listener
        let resolved = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, any Error>) in
            let gate = StartGate(cont) // resume-once guard: .failed after .ready must not double-resume
            listener.stateUpdateHandler = { (state: NWListener.State) in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil // break listener -> handler -> listener retain cycle
                    if let p = listener.port { gate.resume(.success(p.rawValue)) }
                case .failed(let e):
                    listener.stateUpdateHandler = nil
                    gate.resume(.failure(e))
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    gate.resume(.failure(NWError.posix(.ECANCELED)))
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
        if req.method == "GET", req.path == "/health" {
            sendJSON(conn, 200, Data(#"{"status":"ok"}"#.utf8)); return
        }
        if let cl = req.headers["content-length"], Int(cl) == nil {
            sendError(conn, 400, "invalid_request_error"); return
        }
        if req.method == "GET", req.path == "/v1/models" {
            var list = engines.compactMap { $0.listedModel }
                .sorted { $0.id < $1.id }
            if let ext { list += ext.extraModels() }
            sendJSON(conn, 200, try! JSONEncoder().encode(ModelsList(data: list))); return
        }
        if req.path.hasPrefix("/x/") {
            guard let dl = ext?.download else {
                sendError(conn, 501, "not_implemented"); return // Faza-1 default: serwer bez /x/*
            }
            do {
                switch (req.method, req.path) {
                case ("GET", "/x/models"):
                    sendRaw(conn, 200, try await dl.records(), type: "application/json")
                case ("GET", "/x/download/status"):
                    sendRaw(conn, 200, try await dl.status(), type: "application/json")
                case ("POST", "/x/download"):
                    struct DReq: Decodable { let repo: String; let revision: String? }
                    let d: DReq
                    do { d = try JSONDecoder().decode(DReq.self, from: req.body) }
                    catch { throw ServerAPIError.invalidRequest("repo: \(error.localizedDescription)") }
                    try await dl.start(d.repo, d.revision)
                    sendRaw(conn, 202, Data(#"{"accepted":true}"#.utf8), type: "application/json")
                case ("POST", "/x/models/load"):
                    try await dl.load(try Self.decodeId(req.body))
                    sendRaw(conn, 202, Data(#"{"loading":true}"#.utf8), type: "application/json")
                case ("POST", "/x/models/unload"):
                    try await dl.unload(try Self.decodeId(req.body))
                    sendRaw(conn, 200, Data(#"{"unloaded":true}"#.utf8), type: "application/json")
                case ("DELETE", let p) where p.hasPrefix("/x/models/"):
                    let id = String(p.dropFirst("/x/models/".count)).removingPercentEncoding ?? ""
                    guard !id.isEmpty else { throw ServerAPIError.invalidRequest("id wymagane") }
                    try await dl.delete(id)
                    sendRaw(conn, 200, Data(#"{"deleted":true}"#.utf8), type: "application/json")
                default:
                    sendError(conn, 404, "not_found")
                }
            } catch let e as ServerAPIError {
                sendRaw(conn, e.httpStatus, try! JSONEncoder().encode(OpenAIErrorBody(message: "\(e)", type: e.type)), type: "application/json")
            } catch {
                sendRaw(conn, 500, try! JSONEncoder().encode(OpenAIErrorBody(message: "\(error)", type: "server_error")), type: "application/json")
            }
            return // /x/* never busy-gated
        }
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

    private func sendJSON(_ conn: NWConnection, _ status: Int, _ body: Data) {
        sendRaw(conn, status, body, type: "application/json")
    }

    private func sendRaw(_ conn: NWConnection, _ status: Int, _ body: Data, type: String) {
        let h = "HTTP/1.1 \(status) \r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(h.utf8) + body, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func decodeId(_ body: Data) throws -> String {
        struct IdReq: Decodable { let id: String }
        guard let d = try? JSONDecoder().decode(IdReq.self, from: body), !d.id.isEmpty else {
            throw ServerAPIError.invalidRequest("id wymagane")
        }
        return d.id
    }

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
