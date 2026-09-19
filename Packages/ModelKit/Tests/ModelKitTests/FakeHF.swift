import Foundation

final class FakeHF: URLProtocol {
    nonisolated(unsafe) static var files: [String: Data] = [:]   // path po "https://fake.hf/"
    nonisolated(unsafe) static var failOncePath: String?
    nonisolated(unsafe) static var ignoreRange = false
    nonisolated(unsafe) static var lastRangeHeader: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        guard var data = FakeHF.files[path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
        }
        if let fail = FakeHF.failOncePath, fail == path {
            FakeHF.failOncePath = nil
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        var headers: [String: String] = [:]
        var status = 200
        let range = request.value(forHTTPHeaderField: "Range")
        if !FakeHF.ignoreRange, let range,
           let r = range.range(of: #"bytes=(\d+)-"#, options: .regularExpression),
           let start = Int(range[r].dropFirst(6).dropLast()) {
            FakeHF.lastRangeHeader = range
            headers["Content-Range"] = "bytes \(start)-\(data.count - 1)/\(data.count)"
            data = Data(data.dropFirst(start))
            status = 206
        }
        headers["Content-Length"] = "\(data.count)"
        client?.urlProtocol(self, didReceive: Response(status: status, headers: headers), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private final class Response: HTTPURLResponse { init(status: Int, headers: [String: String]? = nil) {
        super.init(url: URL(string: "https://fake.hf")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)! }
        required init?(coder: NSCoder) { super.init(coder: coder) } }
}
