import Foundation
import FoundationModels
import OpenAICompat
import os

@available(iOS 26, *)
final class AFMEngine: InferenceEngine, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.pawel.pocketserve", category: "afm")
    let id = "apple-afm"
    // TODO(phase2): SDK nie ekspozuje okna kontekstu — LanguageModelCapabilities ma tylko
    // vision/guidedGeneration/reasoning/toolCalling; limit widać jedynie w błędzie
    // ContextSizeExceeded(contextSize:tokenCount:). Zostaje 4096 do potwierdzenia na urządzeniu.
    var contextWindow: Int { 4096 }

    // Licznik aktywnych streamów → BackgroundGuard dostaje grant TYLKO w oknie generowania.
    private static let activeStreams = OSAllocatedUnfairLock(initialState: 0)
    static var hasActiveStream: Bool { activeStreams.withLock { $0 > 0 } }

    // Dekrement dokładnie raz per stream (onTermination + punkty terminalne do/catch).
    private static func releaseStream(_ once: OSAllocatedUnfairLock<Bool>) {
        let first = once.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard first else { return }
        let remaining = activeStreams.withLock { count -> Int in
            count -= 1
            return count
        }
        if remaining == 0 {
            Task { @MainActor in BackgroundGuard.shared.streamDidEnd() }
        }
    }

    func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            AFMEngine.activeStreams.withLock { $0 += 1 }
            let once = OSAllocatedUnfairLock(initialState: false)
            let task = Task {
                defer { AFMEngine.releaseStream(once) } // punkty terminalne do/catch
                do {
                    guard SystemLanguageModel.default.availability == .available else {
                        Self.log.error("AFM unavailable — Apple Intelligence is turned off")
                        throw NSError(domain: "afm", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is turned off"])
                    }
                    if #available(iOS 27.0, *) {
                        let caps = SystemLanguageModel.default.capabilities
                        Self.log.info("AFM available; capabilities reasoning=\(caps.contains(.reasoning)) toolCalling=\(caps.contains(.toolCalling)) vision=\(caps.contains(.vision))")
                    } else {
                        Self.log.info("AFM available (iOS 26 — capabilities API unavailable)")
                    }
                    let session = LanguageModelSession()
                    // Mapowanie GenerationParams → SDK (ios-simulator27.0.swiftinterface):
                    // GenerationOptions(samplingMode:temperature:maximumResponseTokens:) — oba labele istnieją.
                    // LanguageModelSession nie ma init(generationOptions:) → options per-request przez streamResponse(options:).
                    let options = GenerationOptions(temperature: params.temperature,
                                                 maximumResponseTokens: params.maxTokens)
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
            continuation.onTermination = { _ in task.cancel(); AFMEngine.releaseStream(once) }
        }
    }
}
