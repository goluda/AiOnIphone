import XCTest
@testable import OpenAICompat

final class AnthropicSSEEncoderTests: XCTestCase {

    private func decodeFrame(_ data: Data, expectedEvent: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("event: \(expectedEvent)\ndata: "), "frame prefix: \(text.prefix(40))", file: file, line: line)
        XCTAssertTrue(text.hasSuffix("\n\n"), "frame terminator", file: file, line: line)
        let json = text.dropFirst("event: \(expectedEvent)\ndata: ".count).dropLast(2)
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testMessageStartFrame() throws {
        let f = decodeFrame(try AnthropicSSEEncoder.messageStart(id: "msg_a", model: "m",
            usage: AnthropicUsage(inputTokens: 7, outputTokens: 0)), expectedEvent: "message_start")
        let m = f["message"] as? [String: Any] ?? [:]
        XCTAssertEqual(f["type"] as? String, "message_start")
        XCTAssertEqual(m["id"] as? String, "msg_a")
        XCTAssertEqual(m["type"] as? String, "message")
        XCTAssertEqual(m["role"] as? String, "assistant")
        XCTAssertEqual(m["model"] as? String, "m")
        XCTAssertEqual((m["content"] as? [Any])?.isEmpty, true)
        let u = m["usage"] as? [String: Any] ?? [:]
        XCTAssertEqual(u["input_tokens"] as? Int, 7)
        XCTAssertEqual(u["output_tokens"] as? Int, 0)
    }

    func testContentBlockFrames() throws {
        let start = decodeFrame(try AnthropicSSEEncoder.contentBlockStart(), expectedEvent: "content_block_start")
        XCTAssertEqual(start["index"] as? Int, 0)
        let block = start["content_block"] as? [String: Any] ?? [:]
        XCTAssertEqual(block["type"] as? String, "text")
        XCTAssertEqual(block["text"] as? String, "")

        let delta = decodeFrame(try AnthropicSSEEncoder.contentBlockDelta(text: "Hello"), expectedEvent: "content_block_delta")
        XCTAssertEqual(delta["index"] as? Int, 0)
        let d = delta["delta"] as? [String: Any] ?? [:]
        XCTAssertEqual(d["type"] as? String, "text_delta")
        XCTAssertEqual(d["text"] as? String, "Hello")

        XCTAssertEqual(decodeFrame(try AnthropicSSEEncoder.contentBlockStop(), expectedEvent: "content_block_stop")["index"] as? Int, 0)
    }

    func testMessageDeltaPingAndStopFrames() throws {
        let f = decodeFrame(try AnthropicSSEEncoder.messageDelta(stopReason: "end_turn", outputTokens: 5), expectedEvent: "message_delta")
        let d = f["delta"] as? [String: Any] ?? [:]
        XCTAssertEqual(d["stop_reason"] as? String, "end_turn")
        XCTAssertTrue(d.keys.contains("stop_sequence"))
        XCTAssertNil(d["stop_sequence"] as? String, "stop_sequence must be JSON null")
        XCTAssertEqual((f["usage"] as? [String: Any])?["output_tokens"] as? Int, 5)

        XCTAssertEqual(decodeFrame(try AnthropicSSEEncoder.messageStop(), expectedEvent: "message_stop")["type"] as? String, "message_stop")
        XCTAssertEqual(decodeFrame(try AnthropicSSEEncoder.ping(), expectedEvent: "ping")["type"] as? String, "ping")
    }

    func testErrorFrame() throws {
        let f = decodeFrame(try AnthropicSSEEncoder.error(message: "boom", type: "api_error"), expectedEvent: "error")
        XCTAssertEqual(f["type"] as? String, "error")
        let e = f["error"] as? [String: Any] ?? [:]
        XCTAssertEqual(e["type"] as? String, "api_error")
        XCTAssertEqual(e["message"] as? String, "boom")
    }

    func testResponseDTOKeys() throws {
        let resp = AnthropicMessageResponse(id: "msg_1", model: "mock",
            content: [AnthropicContentBlock(text: "hi")], stopReason: "end_turn",
            usage: AnthropicUsage(inputTokens: 2, outputTokens: 1))
        let j = (try? JSONSerialization.jsonObject(with: try JSONEncoder().encode(resp))) as? [String: Any] ?? [:]
        XCTAssertEqual(j["type"] as? String, "message")
        XCTAssertEqual(j["role"] as? String, "assistant")
        XCTAssertTrue(j.keys.contains("stop_sequence")); XCTAssertNil(j["stop_sequence"] as? String)
        XCTAssertEqual(j["stop_reason"] as? String, "end_turn")
        let b = (j["content"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(b["type"] as? String, "text")
        XCTAssertEqual(b["text"] as? String, "hi")
    }
}
