import XCTest
@testable import OpenAICompat

final class ContextTruncatorTests: XCTestCase {
    func testKeepsSystemAndNewestWithinBudget() {
        let sys = ChatMessage(role: "system", content: "AAA")          // ~1 tok
        let old = ChatMessage(role: "user", content: String(repeating: "x", count: 400)) // 100 tok
        let new = ChatMessage(role: "user", content: "ok")
        let r = ContextTruncator.truncate(messages: [sys, old, new], budgetTokens: 50)
        XCTAssertEqual(r.kept.map(\.role), ["system", "user"])
        XCTAssertEqual(r.kept.last?.content, "ok")
        XCTAssertGreaterThan(r.droppedTokens, 50)
    }
    func testBudgetCoversAllKeepsAll() {
        let ms = [ChatMessage(role: "user", content: "a"), ChatMessage(role: "assistant", content: "b")]
        XCTAssertEqual(ContextTruncator.truncate(messages: ms, budgetTokens: 1000).kept.count, 2)
    }
}
