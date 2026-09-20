namespace PocketServe.Companion.Core;

using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;

/// <summary>Minimal OpenAI-compatible client for a PocketServe iPhone.</summary>
public sealed class PocketServeClient(HttpClient http)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task<HealthStatus> GetHealthAsync(ServerAddress address, CancellationToken ct)
    {
        using var response = await SendAsync(HttpMethod.Get, $"{address.BaseUrl}/health", content: null, ct);
        return await DeserializeAsync<HealthStatus>(response, ct);
    }

    public async Task<IReadOnlyList<ModelInfo>> GetModelsAsync(ServerAddress address, CancellationToken ct)
    {
        using var response = await SendAsync(HttpMethod.Get, $"{address.BaseUrl}/v1/models", content: null, ct);
        var list = await DeserializeAsync<ModelsResponse>(response, ct);
        return list.Data;
    }

    /// <summary>Yields assistant text deltas from a streaming chat completion.</summary>
    public async IAsyncEnumerable<string> StreamChatAsync(
        ServerAddress address,
        ChatRequest request,
        [EnumeratorCancellation] CancellationToken ct)
    {
        // iPhone RequestParser reads only Content-Length; JsonContent streams lazily
        // (Transfer-Encoding: chunked) and the body arrives empty -> 400.
        var jsonBody = new StringContent(JsonSerializer.Serialize(request, JsonOptions), Encoding.UTF8, "application/json");
        using var response = await SendAsync(
            HttpMethod.Post,
            $"{address.BaseUrl}/v1/chat/completions",
            jsonBody,
            ct);

        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        var reader = new SseReader();
        var buffer = new byte[4096];

        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var read = await stream.ReadAsync(buffer, ct);
            if (read == 0)
            {
                yield break;
            }

            foreach (var payload in reader.Feed(buffer.AsMemory(0, read)))
            {
                var delta = ParseDelta(payload);
                if (delta is not null)
                {
                    yield return delta;
                }
            }
        }
    }

    private static string? ParseDelta(string payload)
    {
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;

        if (root.TryGetProperty("error", out var error))
        {
            var detail = error.TryGetProperty("message", out var message) ? message.GetString() : null;
            throw new PocketServeClientException(
                status: 200,
                userMessage: PocketServeClientException.MapError(500, detail));
        }

        if (!root.TryGetProperty("choices", out var choices)
            || choices.GetArrayLength() == 0
            || !choices[0].TryGetProperty("delta", out var deltaElement)
            || !deltaElement.TryGetProperty("content", out var contentElement))
        {
            return null;
        }

        return contentElement.GetString();
    }

    private async Task<HttpResponseMessage> SendAsync(
        HttpMethod method,
        string url,
        HttpContent? content,
        CancellationToken ct)
    {
        HttpResponseMessage response;
        try
        {
            using var request = new HttpRequestMessage(method, url) { Content = content };
            response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        }
        catch (HttpRequestException)
        {
            throw new PocketServeClientException(0, PocketServeClientException.ConnectFailureMessage);
        }

        if (response.IsSuccessStatusCode)
        {
            return response;
        }

        using (response)
        {
            var detail = await TryReadErrorDetailAsync(response, ct);
            throw new PocketServeClientException(
                (int)response.StatusCode,
                PocketServeClientException.MapError((int)response.StatusCode, detail));
        }
    }

    private static async Task<string?> TryReadErrorDetailAsync(HttpResponseMessage response, CancellationToken ct)
    {
        try
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            var parsed = JsonSerializer.Deserialize<OpenAIErrorBody>(body, JsonOptions);
            return parsed?.Error?.Message;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static async Task<T> DeserializeAsync<T>(HttpResponseMessage response, CancellationToken ct)
    {
        try
        {
            return await response.Content.ReadFromJsonAsync<T>(JsonOptions, ct)
                ?? throw new PocketServeClientException((int)response.StatusCode, "Pusta odpowiedź serwera.");
        }
        catch (JsonException ex)
        {
            throw new PocketServeClientException(
                (int)response.StatusCode,
                PocketServeClientException.MapError((int)response.StatusCode, null),
                ex);
        }
    }
}
