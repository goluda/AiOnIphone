import Foundation

final class FakeHF: URLProtocol {
    nonisolated(unsafe) static var files: [String: Data] = [:]   // path po "https://fake.hf/"
    nonisolated(unsafe) static var failOncePath: String?
    nonisolated(unsafe) static var ignoreRange = false

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
        let range = request.value(forHTTPHeaderField: "Range")
        if !FakeHF.ignoreRange, let range,
           let r = range.range(of: #"bytes=(\d+)-"#, options: .regularExpression),
           let start = Int(range[r].dropFirst(6).dropLast()) {
            let slice = data.dropFirst(start)
            headers["Content-Range"] = "bytes \(start)-\(data.count - 1)/\(data.count)"
            data = Data(slice)
            client?.urlProtocol(self, didReceive: Response(status: 206), cacheStoragePolicy: .notAllowed)
        } else {
            client?.urlProtocol(self, didReceive: Response(status: 200), cacheStoragePolicy: .notAllowed)
        }
        headers["Content-Length"] = "\(data.count)"
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private final class Response: HTTPURLResponse { init(status: Int) {
        super.init(url: URL(string: "https://fake.hf")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)! }
        required init?(coder: NSCoder) { super.init(coder: coder) } }
}
