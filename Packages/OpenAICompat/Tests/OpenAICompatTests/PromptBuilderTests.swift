import XCTest
@testable import OpenAICompat

final class PromptBuilderTests: XCTestCase {
    func testSerializesRoles() {
        let p = PromptBuilder.prompt(from: [
            ChatMessage(role: "system", content: "jesteś asystentem"),
            ChatMessage(role: "user", content: "cześć")])
        XCTAssertEqual(p, "<|system|>\njesteś asystentem\n<|user|>\ncześć\n")
    }
}
