import Foundation

public struct HTTPRequest: Sendable {
    public let method: String; public let path: String
    public let headers: [String: String]; public let body: Data
}

public enum RequestParser {
    public static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = buffer[buffer.startIndex..<sep.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        }
        let need = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[sep.upperBound...]
        guard body.count >= need else { return nil }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                           headers: headers, body: Data(body.prefix(need)))
    }
}
