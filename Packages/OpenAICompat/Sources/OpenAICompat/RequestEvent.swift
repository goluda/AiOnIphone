import Foundation

// One handled HTTP request — emitted via HTTPServer.onRequest for the in-app mini-log. No wire changes.
public struct RequestEvent: Sendable {
    public let method: String
    public let path: String
    public let status: Int
    public let durationMs: Int
    public let model: String?
    public let timestamp: Date
    public init(method: String, path: String, status: Int, durationMs: Int, model: String?, timestamp: Date = Date()) {
        self.method = method; self.path = path; self.status = status
        self.durationMs = durationMs; self.model = model; self.timestamp = timestamp
    }
}
