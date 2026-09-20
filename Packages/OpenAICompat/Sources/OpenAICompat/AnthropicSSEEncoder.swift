import Foundation

public enum AnthropicSSEEncoder {
    private static func frame(_ event: String, _ payload: any Encodable) throws -> Data {
        let json = try JSONEncoder().encode(payload)
        return Data("event: \(event)\ndata: ".utf8) + json + Data("\n\n".utf8)
    }

    public static func messageStart(id: String, model: String, usage: AnthropicUsage) throws -> Data {
        struct Message: Encodable {
            let type: String; let id: String; let role: String; let model: String
            let content: [AnthropicContentBlock]; let usage: AnthropicUsage
        }
        struct Payload: Encodable { let type: String; let message: Message }
        return try frame("message_start", Payload(type: "message_start",
            message: Message(type: "message", id: id, role: "assistant", model: model, content: [], usage: usage)))
    }

    public static func contentBlockStart() throws -> Data {
        struct Payload: Encodable { let type: String; let index: Int; let content_block: AnthropicContentBlock }
        return try frame("content_block_start", Payload(type: "content_block_start", index: 0, content_block: .init(text: "")))
    }

    public static func ping() throws -> Data {
        struct Payload: Encodable { let type: String }
        return try frame("ping", Payload(type: "ping"))
    }

    public static func contentBlockDelta(text: String) throws -> Data {
        struct Delta: Encodable { let type: String; let text: String }
        struct Payload: Encodable { let type: String; let index: Int; let delta: Delta }
        return try frame("content_block_delta", Payload(type: "content_block_delta", index: 0, delta: Delta(type: "text_delta", text: text)))
    }

    public static func contentBlockStop() throws -> Data {
        struct Payload: Encodable { let type: String; let index: Int }
        return try frame("content_block_stop", Payload(type: "content_block_stop", index: 0))
    }

    public static func messageDelta(stopReason: String, outputTokens: Int) throws -> Data {
        struct Delta: Encodable {
            let stop_reason: String
            enum CodingKeys: String, CodingKey { case stop_reason, stop_sequence }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(stop_reason, forKey: .stop_reason)
                try c.encodeNil(forKey: .stop_sequence)
            }
        }
        struct Payload: Encodable { let type: String; let delta: Delta; let usage: AnthropicUsage }
        return try frame("message_delta", Payload(type: "message_delta",
            delta: Delta(stop_reason: stopReason),
            usage: AnthropicUsage(inputTokens: 0, outputTokens: outputTokens)))
    }

    public static func messageStop() throws -> Data {
        struct Payload: Encodable { let type: String }
        return try frame("message_stop", Payload(type: "message_stop"))
    }

    public static func error(message: String, type: String = "api_error") throws -> Data {
        try frame("error", AnthropicErrorBody(errorType: type, message: message))
    }
}
