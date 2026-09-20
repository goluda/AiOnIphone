namespace PocketServe.Companion.Core.Tests;

using System.Net;
using System.Text;

/// <summary>Recorded request; body is buffered because HttpClient disposes request content after send.</summary>
internal sealed record RecordedRequest(Uri? RequestUri, string Body, long? ContentLength);

/// <summary>HttpMessageHandler returning canned responses per queued delegate.</summary>
internal sealed class FakeHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, HttpResponseMessage> _respond;

    public FakeHandler(Func<HttpRequestMessage, HttpResponseMessage> respond)
    {
        _respond = respond;
    }

    public List<RecordedRequest> Requests { get; } = [];

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        // Length must be captured BEFORE reading the body: lazily-buffered content
        // (e.g. JsonContent) fills Content-Length only after serialization,
        // which would mask a chunked wire transfer.
        var contentLength = request.Content?.Headers.ContentLength;
        var body = request.Content is not null ? await request.Content.ReadAsStringAsync(cancellationToken) : string.Empty;
        Requests.Add(new RecordedRequest(request.RequestUri, body, contentLength));
        return _respond(request);
    }

    public static HttpResponseMessage Json(HttpStatusCode status, string json)
        => new(status)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };

    public static HttpResponseMessage Sse(string body)
        => new(HttpStatusCode.OK)
        {
            Content = new StringContent(body, Encoding.UTF8, "text/event-stream"),
        };

}

internal sealed class ThrowingHandler(Exception exception) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        => throw exception;
}
