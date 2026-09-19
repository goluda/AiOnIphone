import XCTest
@testable import OpenAICompat

final class RequestParserTests: XCTestCase {
    func testParsesGetWithoutBody() {
        let raw = "GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n"
        let r = RequestParser.parse(Data(raw.utf8))!
        XCTAssertEqual(r.method, "GET"); XCTAssertEqual(r.path, "/v1/models")
        XCTAssertEqual(r.headers["host"], "x"); XCTAssertEqual(r.body.count, 0)
    }
    func testIncompleteReturnsNil() {
        XCTAssertNil(RequestParser.parse(Data("POST /v1/chat HTTP/1.1\r\nContent-Length: 5\r\n\r".utf8)))
    }
    func testNilUntilBodyComplete() {
        var data = Data("POST /v1/chat HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8)
        XCTAssertNil(RequestParser.parse(data)) // headers present, body short -> nil
        data.append(contentsOf: "cd".utf8)
        XCTAssertEqual(RequestParser.parse(data)?.body, Data("abcd".utf8))
    }
    func testWaitsForFullBody() {
        var r: HTTPRequest?
        var data = Data()
        for b in "POST /v1/chat HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8 {
            data.append(b)
            r = RequestParser.parse(data)
        }
        XCTAssertEqual(r?.body, Data("{}".utf8))
    }
}
