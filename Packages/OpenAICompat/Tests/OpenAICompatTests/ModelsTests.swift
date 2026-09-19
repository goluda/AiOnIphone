import XCTest
@testable import OpenAICompat

final class ModelsTests: XCTestCase {
    func testChatMessageRoundTrip() throws {
        let json = #"{"role":"user","content":"hej"}"#
        let msg = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg, ChatMessage(role: "user", content: "hej"))
        let back = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(msg))
        XCTAssertEqual(back, ["role": "user", "content": "hej"]) // kolejność kluczy JSONEncoder niezdefiniowana
    }
}
