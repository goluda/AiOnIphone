import Foundation

public struct AnthropicContentBlock: Codable, Sendable, Equatable {
    public let type: String
    public let text: String
    public init(type: String = "text", text: String) { self.type = type; self.text = text }
}

public struct AnthropicUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

public struct AnthropicMessageResponse: Codable, Sendable {
    public let id: String
    public let type: String
    public let role: String
    public let model: String
    public let content: [AnthropicContentBlock]
    public let stopReason: String?
    public let stopSequence: String?
    public let usage: AnthropicUsage
    enum CodingKeys: String, CodingKey {
        case id, type, role, model, content, usage
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }
    public init(id: String, model: String, content: [AnthropicContentBlock],
                stopReason: String?, usage: AnthropicUsage) {
        self.id = id; self.type = "message"; self.role = "assistant"; self.model = model
        self.content = content; self.stopReason = stopReason; self.stopSequence = nil; self.usage = usage
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(type, forKey: .type)
        try c.encode(role, forKey: .role); try c.encode(model, forKey: .model)
        try c.encode(content, forKey: .content); try c.encode(usage, forKey: .usage)
        try c.encodeIfPresent(stopReason, forKey: .stopReason)
        try c.encodeNil(forKey: .stopSequence)
    }
}

public struct AnthropicErrorBody: Codable, Sendable {
    public struct ErrorDetail: Codable, Sendable {
        public let type: String
        public let message: String
    }
    public let type: String
    public let error: ErrorDetail
    public init(errorType: String, message: String) {
        self.type = "error"; self.error = ErrorDetail(type: errorType, message: message)
    }
}
