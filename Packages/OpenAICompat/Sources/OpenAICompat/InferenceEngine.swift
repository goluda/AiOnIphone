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
    private let latency: Duration
    public init(id: String = "mock", contextWindow: Int = 4096,
                tokens: [String] = ["To", " jest", " mock"], latency: Duration = .zero) {
        self.id = id; self.contextWindow = contextWindow; self.tokens = tokens; self.latency = latency
    }
    public nonisolated func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> {
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
