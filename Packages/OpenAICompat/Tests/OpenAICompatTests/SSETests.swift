import XCTest
@testable import OpenAICompat

final class SSETests: XCTestCase {
    func testEncodeChunkHasBlankLineTerminator() throws {
        let c = ChatCompletionChunk(id: "a", created: 1, model: "m",
            choices: [.init(index: 0, delta: .init(content: "x"), finishReason: nil)])
        let d = try SSEEncoder.encode(c)
        XCTAssertEqual(String(data: d, encoding: .utf8)!.suffix(2), "\n\n")
    }
    func testDoneSentinel() { XCTAssertEqual(String(data: SSEEncoder.done, encoding: .utf8), "data: [DONE]\n\n") }
    func testParserHandlesSplitAcrossFeeds() {
        var p = SSEParser()
        let full = "data: {\"x\":1}\n\ndata: [DONE]\n\n"
        var out: [String] = []
        for b in full.utf8 { out += p.feed(Data([b])) }
        XCTAssertEqual(out, ["{\"x\":1}"])
    }
    func testParserIgnoresComments() {
        var p = SSEParser()
        XCTAssertEqual(p.feed(Data(": keep-alive\n\n".utf8)), [])
    }
    func testParserSurvivesMultiByteSplit() {
        var p = SSEParser()
        let payload = "data: żółw\n\n"
        var out: [String] = []
        for b in payload.utf8 { out += p.feed(Data([b])) }
        XCTAssertEqual(out, ["żółw"])
    }
}
