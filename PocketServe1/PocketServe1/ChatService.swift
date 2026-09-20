import Foundation
import OpenAICompat

struct ChatServiceError: LocalizedError {
    let userMessage: String
    var errorDescription: String? { userMessage }
}

// Klient loopback-API własnego serwera: czat w aplikacji przechodzi przez ten sam HTTP co zewnętrzni klienci.
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
                req.timeoutInterval = 300 // mlx: pierwsze tokeny mogą trwać długo
                do {
                    req.httpBody = try JSONEncoder().encode(request)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw ChatServiceError(userMessage: "Nieoczekiwana odpowiedź serwera")
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
                            // Ramka błędu w trakcie streamu (SSEEncoder.encodeError) → przerwij z komunikatem.
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
                    continuation.finish() // Stop przycisku — normalne zakończenie
                } catch let e as ChatServiceError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: ChatServiceError(userMessage: "Brak połączenia z serwerem — uruchom go na ekranie głównym"))
                }
            }
            activeTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() { activeTask?.cancel(); activeTask = nil }

    static func mapError(status: Int, detail: String?) -> String {
        switch status {
        case 404: return detail ?? "Nieznany model"
        case 409: return "Model nie załadowany — wczytaj go w widoku Modele"
        case 429: return "Serwer zajęty — poczekaj na koniec bieżącego żądania"
        case 400: return "Złe zapytanie do serwera"
        default: return detail ?? "Błąd serwera (\(status))"
        }
    }
}
