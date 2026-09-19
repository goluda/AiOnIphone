import Foundation
import FoundationModels
import OpenAICompat

@available(iOS 26, *)
final class AFMEngine: InferenceEngine, @unchecked Sendable {
    let id = "apple-afm"
    var contextWindow: Int { 4096 } // potwierdź capabilities AFM 3B w iOS 27
    func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard SystemLanguageModel.default.availability == .available else {
                        throw NSError(domain: "afm", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence wyłączony"])
                    }
                    let session = LanguageModelSession()
                    // brief: GenerationOptions(excludedInstructions: []) — label nie istnieje w SDK Xcode 27; defaults ekwiwalentne
                    let options = GenerationOptions()
                    // Xcode 27 SDK: streamResponse zwraca kumulatywne Snapshoty; HTTPServer (MockEngine)
                    // oczekuje inkrementalnych fragmentów → emitujemy tylko nowy sufiks.
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let full = snapshot.content
                        let delta = full.hasPrefix(sent) ? String(full.dropFirst(sent.count)) : full
                        if !delta.isEmpty { continuation.yield(delta) }
                        sent = full
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
