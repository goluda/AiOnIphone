import Foundation

public enum SSEEncoder {
    public static let done = Data("data: [DONE]\n\n".utf8)
    public static func encode(_ chunk: ChatCompletionChunk) throws -> Data {
        var json = try JSONEncoder().encode(chunk)
        var out = Data("data: ".utf8); out.append(json); out.append("\n\n".data(using: .utf8)!)
        return out
    }
    // I-1: błąd w trakcie streamu → event OpenAI {"error":{...}} w ramach otwartego SSE (nagłówki 200 wysłane).
    public static func encodeError(_ message: String, type: String = "server_error") -> Data {
        struct Err: Encodable { let message: String; let type: String }
        struct Body: Encodable { let error: Err }
        var json = try! JSONEncoder().encode(Body(error: Err(message: message, type: type)))
        var out = Data("data: ".utf8); out.append(json); out.append("\n\n".data(using: .utf8)!)
        return out
    }
}

public struct SSEParser {
    private var buffer = Data()
    public init() {}
    public mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var events: [String] = []
        while let range = buffer.range(of: Data([0x0A, 0x0A])) {
            let eventData = buffer[buffer.startIndex..<range.lowerBound]
            buffer.removeSubrange(..<range.upperBound)
            guard let event = String(data: eventData, encoding: .utf8) else { continue }
            for line in event.components(separatedBy: "\n") where line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                if payload != "[DONE]" { events.append(payload) }
            }
        }
        return events
    }
}
