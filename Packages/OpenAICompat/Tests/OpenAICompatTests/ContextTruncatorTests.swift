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
    func testTruncationKeepsContiguousNewestSuffixOnly() {
        let sys = ChatMessage(role: "system", content: "S")                    // 1+1+4 = 6
        let a = ChatMessage(role: "user", content: String(repeating: "a", count: 40))   // 1+10+4 = 15
        let b = ChatMessage(role: "user", content: String(repeating: "b", count: 400))  // 1+100+4 = 105
        let c = ChatMessage(role: "user", content: String(repeating: "c", count: 40))   // 1+10+4 = 15
        // budget 36: sys(6)+c(15)=21 fits, b(105) dropped; a(15) only fits non-contiguously (21+15=36)
        let kept = ContextTruncator.truncate(messages: [sys, a, b, c], budgetTokens: 36).kept
        XCTAssertEqual(kept.map(\.content), ["S", String(repeating: "c", count: 40)]) // b dropped => a must NOT be kept
    }
    func testBudgetCoversAllKeepsAll() {
        let ms = [ChatMessage(role: "user", content: "a"), ChatMessage(role: "assistant", content: "b")]
        XCTAssertEqual(ContextTruncator.truncate(messages: ms, budgetTokens: 1000).kept.count, 2)
    }
}
