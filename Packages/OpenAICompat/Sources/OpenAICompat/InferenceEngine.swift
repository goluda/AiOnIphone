import Foundation

public protocol InferenceEngine: Sendable {
    var id: String { get }
    var contextWindow: Int { get }
    // Silnik dynamicznego id (faza 2, mlx): przejmuje prefiks modeli; niezarejestrowany exact-id
    // z tym prefiksem → 409 model_not_ready zamiast 404. Domyślnie: silnik statyczny.
    var prefixOwned: String? { get }
    var listedModel: ModelInfo? { get }
    func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error>
}

public extension InferenceEngine {
    var prefixOwned: String? { nil }
    var listedModel: ModelInfo? { ModelInfo(id: id, created: 0, contextWindow: contextWindow) }
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
