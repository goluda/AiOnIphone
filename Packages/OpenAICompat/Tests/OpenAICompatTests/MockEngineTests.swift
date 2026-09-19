import XCTest
@testable import OpenAICompat

final class MockEngineTests: XCTestCase {
    func testStreamsCannedPolishTokensChunkwise() async throws {
        let engine = MockEngine(tokens: ["To", " jest", " mock"], latency: .milliseconds(1))
        XCTAssertEqual(engine.id, "mock")
        XCTAssertEqual(engine.contextWindow, 4096)
        let stream = engine.stream(prompt: "pytanie",
                                    params: GenerationParams(temperature: 0.7, maxTokens: 16))
        var chunks: [String] = []
        for try await chunk in stream { chunks.append(chunk) }
        XCTAssertEqual(chunks, ["To", " jest", " mock"])
    }
}
