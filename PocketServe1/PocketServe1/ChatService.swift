import Foundation
import OpenAICompat

struct ChatServiceError: LocalizedError {
    let userMessage: String
    var errorDescription: String? { userMessage }
}

// Loopback API client for our own server: in-app chat goes through the same HTTP as external clients.
@MainActor
final class ChatService {
    private var activeTask: Task<Void, Never>?

    func models(port: UInt16) async throws -> [String] {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(ModelsList.self, from: data).data.map(\.id)
    }

    func stream(port: UInt16, request: ChatCompletionRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 300 // mlx: first tokens can take a long time
                do {
                    req.httpBody = try JSONEncoder().encode(request)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw ChatServiceError(userMessage: "Unexpected server response")
                    }
                    if http.statusCode != 200 {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        let detail = try? JSONDecoder().decode(OpenAIErrorBody.self, from: body)
                        throw ChatServiceError(userMessage: Self.mapError(status: http.statusCode, detail: detail?.error.message))
                    }
                    var parser = SSEParser()
                    for try await b in bytes {
                        for payload in parser.feed(Data([b])) {
                            let data = Data(payload.utf8)
                            // Error frame mid-stream (SSEEncoder.encodeError) → abort with message.
                            if let err = try? JSONDecoder().decode(OpenAIErrorBody.self, from: data) {
                                throw ChatServiceError(userMessage: err.error.message)
                            }
                            if let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data),
                               let content = chunk.choices.first?.delta.content {
                                continuation.yield(content)
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish() // Stop button — normal termination
                } catch let e as ChatServiceError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: ChatServiceError(userMessage: "No connection to the server — start it on the home screen"))
                }
            }
            activeTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() { activeTask?.cancel(); activeTask = nil }

    static func mapError(status: Int, detail: String?) -> String {
        switch status {
        case 404: return detail ?? "Unknown model"
        case 409: return "Model not loaded — load it in the Models view"
        case 429: return "Server busy — wait for the current request to finish"
        case 400: return "Bad request"
        default: return detail ?? "Server error (\(status))"
        }
    }
}
