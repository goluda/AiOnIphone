import Foundation

public struct ChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public struct ChatCompletionRequest: Codable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let stream: Bool
    public let temperature: Double
    public let maxTokens: Int
    public init(model: String, messages: [ChatMessage], stream: Bool = false,
                temperature: Double = 0.7, maxTokens: Int = 512) {
        self.model = model; self.messages = messages; self.stream = stream
        self.temperature = temperature; self.maxTokens = maxTokens
    }
    enum CodingKeys: String, CodingKey { case model, messages, stream, temperature
        case maxTokens = "max_tokens" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        messages = try c.decode([ChatMessage].self, forKey: .messages)
        stream = try c.decodeIfPresent(Bool.self, forKey: .stream) ?? false
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 512
    }
}

public struct Delta: Codable, Sendable, Equatable { public let content: String?
    public init(content: String?) { self.content = content } }

public struct ChunkChoice: Codable, Sendable { public let index: Int
    public let delta: Delta
    public let finishReason: String?
    public init(index: Int, delta: Delta, finishReason: String?) {
        self.index = index; self.delta = delta; self.finishReason = finishReason }
    enum CodingKeys: String, CodingKey { case index, delta
        case finishReason = "finish_reason" }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(delta, forKey: .delta)
        if let fr = finishReason { try c.encode(fr, forKey: .finishReason) }
        else { try c.encodeNil(forKey: .finishReason) }
    } }

public struct ChatCompletionChunk: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [ChunkChoice]
    public init(id: String, created: Int, model: String, choices: [ChunkChoice]) {
        self.id = id; self.object = "chat.completion.chunk"; self.created = created
        self.model = model; self.choices = choices } }

public struct Usage: Codable, Sendable { public let promptTokens: Int
    public let completionTokens: Int
    enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens" }
    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens } }

public struct ResponseChoice: Codable, Sendable { public let index: Int
    public let message: ChatMessage
    public let finishReason: String?
    public init(index: Int, message: ChatMessage, finishReason: String?) {
        self.index = index; self.message = message; self.finishReason = finishReason }
    enum CodingKeys: String, CodingKey { case index, message
        case finishReason = "finish_reason" } }

public struct CompletionResponse: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [ResponseChoice]
    public let usage: Usage
    public init(id: String, created: Int, model: String, choices: [ResponseChoice], usage: Usage) {
        self.id = id; self.object = "chat.completion"; self.created = created
        self.model = model; self.choices = choices; self.usage = usage } }

public struct OpenAIErrorBody: Codable, Sendable { public let error: ErrorDetail
    public struct ErrorDetail: Codable, Sendable { public let message: String; public let type: String }
    public init(message: String, type: String) { error = ErrorDetail(message: message, type: type) } }

public struct ModelInfo: Codable, Sendable, Equatable { public let id: String
    public let object: String
    public let created: Int
    public let contextWindow: Int
    public init(id: String, created: Int, contextWindow: Int) {
        self.id = id; self.object = "model"; self.created = created
        self.contextWindow = contextWindow }
    enum CodingKeys: String, CodingKey { case id, object, created
        case contextWindow = "context_window" } }

public struct ModelsList: Codable, Sendable { public let object: String
    public let data: [ModelInfo]
    public init(data: [ModelInfo]) { self.object = "list"; self.data = data } }

public struct GenerationParams: Sendable, Equatable { public let temperature: Double
    public let maxTokens: Int
    public init(temperature: Double, maxTokens: Int) {
        self.temperature = temperature; self.maxTokens = maxTokens } }
