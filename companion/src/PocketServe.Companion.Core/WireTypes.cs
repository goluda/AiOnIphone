namespace PocketServe.Companion.Core;

using System.Text.Json.Serialization;

/// <summary>Response of GET /health.</summary>
public sealed record HealthStatus([property: JsonPropertyName("status")] string Status);

/// <summary>One model entry of GET /v1/models.</summary>
public sealed record ModelInfo(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("context_window")] int ContextWindow);

/// <summary>Chat message on the wire (OpenAI shape).</summary>
public sealed record WireMessage(
    [property: JsonPropertyName("role")] string Role,
    [property: JsonPropertyName("content")] string Content);

/// <summary>POST /v1/chat/completions body.</summary>
public sealed record ChatRequest(
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("messages")] IReadOnlyList<WireMessage> Messages,
    [property: JsonPropertyName("stream")] bool Stream = true);

internal sealed record ModelsResponse(
    [property: JsonPropertyName("object")] string Object,
    [property: JsonPropertyName("data")] List<ModelInfo> Data);

internal sealed record OpenAIErrorDetail(
    [property: JsonPropertyName("message")] string? Message,
    [property: JsonPropertyName("type")] string? Type);

internal sealed record OpenAIErrorBody(
    [property: JsonPropertyName("error")] OpenAIErrorDetail? Error);
