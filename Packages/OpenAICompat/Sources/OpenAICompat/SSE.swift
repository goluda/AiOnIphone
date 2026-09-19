import Foundation

public enum SSEEncoder {
    public static let done = Data("data: [DONE]\n\n".utf8)
    public static func encode(_ chunk: ChatCompletionChunk) throws -> Data {
        var json = try JSONEncoder().encode(chunk)
        var out = Data("data: ".utf8); out.append(json); out.append("\n\n".data(using: .utf8)!)
        return out
    }
}

public struct SSEParser {
    private var buffer = ""
    public init() {}
    public mutating func feed(_ data: Data) -> [String] {
        buffer += String(decoding: data, as: UTF8.self)
        var events: [String] = []
        while let range = buffer.range(of: "\n\n") {
            let event = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            for line in event.components(separatedBy: "\n") where line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                if payload != "[DONE]" { events.append(payload) }
            }
        }
        return events
    }
}
