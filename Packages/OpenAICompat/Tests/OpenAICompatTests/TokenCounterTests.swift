import XCTest
@testable import OpenAICompat

final class TokenCounterTests: XCTestCase {
    func testApproxOneTokenPerFourChars() {
        XCTAssertEqual(TokenCounter.approximate("1234567890"), 2)
        XCTAssertGreaterThanOrEqual(TokenCounter.approximate("a"), 1)
    }
}
