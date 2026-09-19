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
    func testRequestDecodesSnakeCaseDefaults() throws {
        let json = #"{"model":"apple-afm","messages":[{"role":"user","content":"hi"}]}"#
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(req.model, "apple-afm")
        XCTAssertFalse(req.stream)
        XCTAssertEqual(req.temperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(req.maxTokens, 512)
    }
    func testChunkEncodesOpenAIShape() throws {
        let c = ChatCompletionChunk(id: "chatcmpl-1", created: 2, model: "apple-afm",
            choices: [.init(index: 0, delta: .init(content: "x"), finishReason: nil)])
        let d = (try? JSONEncoder().encode(c)).flatMap { String(data: $0, encoding: .utf8) }!
        XCTAssertTrue(d.contains("\"object\":\"chat.completion.chunk\""))
        XCTAssertTrue(d.contains("\"finish_reason\":null"))
    }
    func testErrorBodyShape() throws {
        let e = OpenAIErrorBody(message: "nope", type: "invalid_request_error")
        let d = (try? JSONEncoder().encode(e)).flatMap { String(data: $0, encoding: .utf8) }!
        XCTAssertTrue(d.contains(#""error":{""#))
    }
    func testCompletionResponseUsesMessageKey() throws {
        let r = CompletionResponse(id: "x", created: 1, model: "m",
            choices: [.init(index: 0, message: ChatMessage(role: "assistant", content: "hi"), finishReason: "stop")],
            usage: .init(promptTokens: 2, completionTokens: 3))
        let d = (try? JSONEncoder().encode(r)).flatMap { String(data: $0, encoding: .utf8) }!
        XCTAssertTrue(d.contains(#""message":{"role":"assistant","content":"hi"}"#), d)
        XCTAssertFalse(d.contains(#""delta""#), d)
    }
}
