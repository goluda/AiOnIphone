import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom
import OpenAICompat
import os

// mlx-swift-examples 2.29.1 (mlx-swift 0.29.1) — API zweryfikowane w SourcePackages/checkouts:
// - `LLMModel` JEST TYLKO protokołem-markera (MLXLLM/LLMModel.swift); ładowanie i generacja
//   idą przez `ModelContainer`/`ModelContext` (MLXLMCommon) + `LLMModelFactory.shared`.
// - Odczyt wariantu B: `MLXLMCommon.generate(input:cache:parameters:context:) throws -> AsyncStream<Generation>`
//   — `Generation.chunk(String)` = już INKREMENTALNY fragment (NaiveStreamingDetokenizer);
//   `container.perform` daje dostęp do `ModelContext`; chunk → passthrough bez guarda kumulacyjnego.
// - Offline: `ModelConfiguration(directory: URL)` → `downloadModel` zwraca katalog bez HF snapshot,
//   `loadTokenizerConfig` czyta tokenizer z `modelFolder` (brak re-fetch z Hub).
// - `modelContextLength` NIE ISTNIEJE w 2.29.1 → stała 8192 (do potwierdzenia na urządzeniu, Task 7).
// - `MXLClearMalloc()` NIE ISTNIEJE → `MLX.GPU.clearCache()` (mlx-swift/Source/MLX/GPU.swift:364).
final class MLXEngine: InferenceEngine, @unchecked Sendable {
    static let shared = MLXEngine()
    private init() {}

    private static let lock = NSLock()
    private static var _loadedId: String?   // "mlx:<repo>" albo nil
    private static var _container: ModelContainer?

    // Licznik aktywnych streamów — straż unload vs trwająca generacja (/x/unload)
    // + BackgroundGuard (I-2: grant w tle TYLKO w oknie generowania, wzór AFMEngine 1:1).
    private static let streamsLock = NSLock()
    private static var _activeStreams = 0
    nonisolated static var activeStreams: Int { streamsLock.withLock { _activeStreams } }
    nonisolated var activeStreams: Int { Self.activeStreams }

    // Dekrement dokładnie raz per stream (onTermination + punkty terminalne do/catch) — wzór AFMEngine.
    private static func releaseStream(_ once: OSAllocatedUnfairLock<Bool>) {
        let first = once.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard first else { return }
        let remaining = streamsLock.withLock { () -> Int in
            _activeStreams -= 1
            return _activeStreams
        }
        if remaining == 0 {
            Task { @MainActor in BackgroundGuard.shared.streamDidEnd() }
        }
    }

    nonisolated static var loadedId: String? { lock.withLock { _loadedId } }

    nonisolated var id: String { Self.loadedId ?? "mlx:none" }
    // 2.29.1 nie ekspozuje okna kontekstu modelu — 8192 jako konserwatywne przybliżenie (Task 7: potwierdzić).
    nonisolated var contextWindow: Int { 8192 }
    // Serwer: "mlx:*" to nasz prefiks → niezaładowany = 409 model_not_ready; na liście tylko gdy załadowany.
    nonisolated var prefixOwned: String? { "mlx:" }
    nonisolated var listedModel: ModelInfo? {
        Self.loadedId.map { ModelInfo(id: $0, created: 0, contextWindow: contextWindow) }
    }

    nonisolated func loadRecord(_ repo: String, revision: String, folder: URL) async throws {
        await unloadNow()
        MLXRandom.seed(42)
        let config = ModelConfiguration(directory: folder) // ścieżka lokalna: zero networku (Load.swift `.directory`)
        let container = try await LLMModelFactory.shared.loadContainer(configuration: config)
        Self.lock.withLock { Self._container = container; Self._loadedId = "mlx:\(repo)" }
    }

    nonisolated func unloadNow() async {
        // Czekaj aż streamy wygasną (50ms poll, max 10s); po timeout idziemy dalej i tak.
        let deadline = Date().addingTimeInterval(10)
        while Self.activeStreams > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        Self.lock.withLock { Self._container = nil; Self._loadedId = nil }
        GPU.clearCache() // zwalnia zbuforowane bufory Metal (zamiennik nieistniejącego MXLClearMalloc)
    }

    nonisolated func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            Self.streamsLock.withLock { Self._activeStreams += 1 }
            let once = OSAllocatedUnfairLock(initialState: false)
            let task = Task {
                defer { Self.releaseStream(once) } // punkty terminalne do/catch
                guard let container = Self.lock.withLock({ Self._container }) else {
                    continuation.finish(throwing: NSError(domain: "mlx", code: 2, userInfo: [NSLocalizedDescriptionKey: "model nie załadowany"])); return
                }
                let gp = GenerateParameters(maxTokens: params.maxTokens, temperature: Float(params.temperature))
                do {
                    try await container.perform { (context: ModelContext) in
                        let input = UserInput(prompt: prompt)
                        let lmInput = try await context.processor.prepare(input: input)
                        let stream = try generate(input: lmInput, parameters: gp, context: context)
                        for await generation in stream {
                            guard let chunk = generation.chunk else { continue } // .info/.toolCall pominięte
                            // 2.29.1: chunk = inkrement (NaiveStreamingDetokenizer) → passthrough prosto do SSE.
                            if !chunk.isEmpty { continuation.yield(chunk) }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel(); Self.releaseStream(once) }
        }
    }
}
