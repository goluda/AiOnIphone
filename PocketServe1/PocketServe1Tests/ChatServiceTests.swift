import Testing
import Foundation
import OpenAICompat
@testable import PocketServe1

@MainActor
struct ChatServiceTests {
    // Serwer in-process na porcie losowym — prawdziwy HTTP przez loopback.
    private func withServer(_ engines: [any InferenceEngine], _ block: (UInt16) async throws -> Void) async throws {
        let server = HTTPServer(engines: engines)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        try await block(port)
    }

    @Test func modelsReturnsIds() async throws {
        try await withServer([MockEngine(id: "apple-afm", tokens: ["To", " jest", " mock"])]) { port in
            let ids = try await ChatService().models(port: port)
            #expect(ids == ["apple-afm"])
        }
    }

    @Test func streamCollectsTokens() async throws {
        try await withServer([MockEngine(id: "apple-afm", tokens: ["To", " jest", " mock"])]) { port in
            let req = ChatCompletionRequest(model: "apple-afm",
                messages: [ChatMessage(role: "user", content: "czość")], stream: true)
            var out = ""
            for try await tok in ChatService().stream(port: port, request: req) { out += tok }
            #expect(out == "To jest mock")
        }
    }

    @Test func unknownModelThrowsUserMessage() async throws {
        try await withServer([MockEngine(id: "apple-afm", tokens: ["x"])]) { port in
            let req = ChatCompletionRequest(model: "mlx:none",
                messages: [ChatMessage(role: "user", content: "hej")], stream: true)
            do {
                for try await _ in ChatService().stream(port: port, request: req) {}
                Issue.record("oczekiwano rzucenia błędu")
            } catch let e as ChatServiceError {
                #expect(e.userMessage.lowercased().contains("model"))
            }
        }
    }

    @Test func midStreamErrorSurfacesMessage() async throws {
        try await withServer([ThrowingMidStreamEngine()]) { port in
            let req = ChatCompletionRequest(model: "boom",
                messages: [ChatMessage(role: "user", content: "x")], stream: true)
            do {
                for try await _ in ChatService().stream(port: port, request: req) {}
                Issue.record("oczekiwano rzucenia błędu")
            } catch let e as ChatServiceError {
                #expect(e.userMessage == "engine padł")
            }
        }
    }

    @Test func stopCancelsStreamCleanly() async throws {
        try await withServer([MockEngine(id: "apple-afm", tokens: ["a", "b", "c"], latency: .milliseconds(100))]) { port in
            let svc = ChatService()
            let req = ChatCompletionRequest(model: "apple-afm",
                messages: [ChatMessage(role: "user", content: "x")], stream: true)
            var out = ""
            for try await tok in svc.stream(port: port, request: req) {
                out += tok
                if out.count >= 1 { svc.stop() }
            }
            #expect(out.count <= 3) // brak hanga, strumień zakończony po stop
        }
    }
}

private struct ThrowingMidStreamEngine: InferenceEngine {
    var id: String { "boom" }
    var contextWindow: Int { 4096 }
    func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { c in
            c.yield("ok ")
            struct Boom: Error, LocalizedError { var errorDescription: String? { "engine padł" } }
            c.finish(throwing: Boom())
        }
    }
}
