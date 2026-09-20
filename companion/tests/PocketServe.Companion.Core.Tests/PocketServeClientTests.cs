namespace PocketServe.Companion.Core.Tests;

using System.Net;
using System.Runtime.CompilerServices;
using System.Text;
using PocketServe.Companion.Core;
using Shouldly;

[TestFixture]
public sealed class PocketServeClientTests
{
    private static readonly ServerAddress Addr = new("192.168.68.27", 8080);

    private static PocketServeClient ClientWith(FakeHandler handler)
        => new(new HttpClient(handler));

    [Test]
    public async Task GetHealthAsync_Ok_ReturnsStatus()
    {
        using var handler = new FakeHandler(_ => FakeHandler.Json(HttpStatusCode.OK, """{"status":"ok"}"""));
        var client = ClientWith(handler);

        var health = await client.GetHealthAsync(Addr, CancellationToken.None);

        health.Status.ShouldBe("ok");
        handler.Requests.ShouldHaveSingleItem().RequestUri!.ToString()
            .ShouldBe("http://192.168.68.27:8080/health");
    }

    [Test]
    public async Task GetModelsAsync_ReturnsIdsAndContextWindow()
    {
        var json = """
            {"object":"list","data":[
              {"id":"apple-afm","object":"model","created":1,"context_window":4096},
              {"id":"mlx:Qwen/Qwen3-4B-MLX-4bit","object":"model","created":2,"context_window":8192}
            ]}
            """;
        using var handler = new FakeHandler(_ => FakeHandler.Json(HttpStatusCode.OK, json));
        var client = ClientWith(handler);

        var models = await client.GetModelsAsync(Addr, CancellationToken.None);

        models.Select(m => m.Id).ShouldBe(["apple-afm", "mlx:Qwen/Qwen3-4B-MLX-4bit"]);
        models[1].ContextWindow.ShouldBe(8192);
    }

    [Test]
    public async Task StreamChatAsync_YieldsConcatenatedDeltas_AndPostsOpenAiShape()
    {
        var sse = string.Concat(
            Chunk("To "),
            Chunk("jest "),
            Chunk("mock"),
            "data: [DONE]\n\n");
        using var handler = new FakeHandler(_ => FakeHandler.Sse(sse));
        var client = ClientWith(handler);
        var request = new ChatRequest("apple-afm", [new WireMessage("user", "cześć")]);

        var tokens = new List<string>();
        await foreach (var token in client.StreamChatAsync(Addr, request, CancellationToken.None))
        {
            tokens.Add(token);
        }

        string.Concat(tokens).ShouldBe("To jest mock");

        var posted = handler.Requests.ShouldHaveSingleItem();
        posted.RequestUri?.ToString().ShouldBe("http://192.168.68.27:8080/v1/chat/completions");
        posted.Body.ShouldContain("\"stream\":true");
        posted.Body.ShouldContain("\"model\":\"apple-afm\"");
        posted.Body.ShouldContain("\"role\":\"user\"");
    }

    [Test]
    public void StreamChatAsync_MidStreamError_ThrowsWithFrameMessage()
    {
        var sse =
            Chunk("ok ") +
            """data: {"error":{"message":"engine padł","type":"server_error"}}""" + "\n\n";
        using var handler = new FakeHandler(_ => FakeHandler.Sse(sse));
        var client = ClientWith(handler);

        var consumed = 0;
        var ex = Assert.ThrowsAsync<PocketServeClientException>(async () =>
        {
            await foreach (var _ in client.StreamChatAsync(Addr, Req(), CancellationToken.None))
            {
                consumed++;
            }
        });

        consumed.ShouldBe(1);
        ex.UserMessage.ShouldBe("engine padł");
    }

    [Test]
    public async Task GetModelsAsync_409_MapsPolishMessage()
    {
        using var handler = new FakeHandler(_ => FakeHandler.Json((HttpStatusCode)409, """{"error":{"message":"model nie znaleziony","type":"invalid_request"}}"""));
        var client = ClientWith(handler);

        var ex = Assert.ThrowsAsync<PocketServeClientException>(
            () => client.GetModelsAsync(Addr, CancellationToken.None));

        ex!.UserMessage.ShouldBe("model nie znaleziony");
        ex.Status.ShouldBe(409);
    }

    [Test]
    public async Task StreamChatAsync_429WithoutDetail_MapsDefaultPolishMessage()
    {
        using var handler = new FakeHandler(_ => FakeHandler.Json((HttpStatusCode)429, "{}"));
        var client = ClientWith(handler);

        var ex = Assert.ThrowsAsync<PocketServeClientException>(() =>
            DrainAsync(client, CancellationToken.None));

        ex!.Status.ShouldBe(429);
        ex.UserMessage.ShouldBe("Serwer zajęty — poczekaj na koniec generowania.");
    }

    [Test]
    public async Task GetModelsAsync_404_MapsPolishMessage()
    {
        using var handler = new FakeHandler(_ => FakeHandler.Json(HttpStatusCode.NotFound, "{}"));
        var client = ClientWith(handler);

        var ex = Assert.ThrowsAsync<PocketServeClientException>(
            () => client.GetModelsAsync(Addr, CancellationToken.None));

        ex!.UserMessage.ShouldBe("Nie znaleziono modelu lub endpointu.");
    }

    [Test]
    public void GetModelsAsync_RequestFailure_MapsConnectMessage()
    {
        using var handler = new ThrowingHandler(new HttpRequestException("refused"));
        var client = new PocketServeClient(new HttpClient(handler));

        var ex = Assert.ThrowsAsync<PocketServeClientException>(
            () => client.GetModelsAsync(Addr, CancellationToken.None));

        ex!.Status.ShouldBe(0);
        ex.UserMessage.ShouldBe("Brak połączenia z iPhonem. Sprawdź adres i czy serwer działa.");
    }

    [Test]
    public void StreamChatAsync_Cancellation_PropagatesOperationCanceled()
    {
        using var cts = new CancellationTokenSource();
        var handler = new LateHandler(cts);
        var client = new PocketServeClient(new HttpClient(handler));

        Assert.ThrowsAsync<OperationCanceledException>(async () =>
        {
            await foreach (var _ in client.StreamChatAsync(Addr, Req(), cts.Token))
            {
                await cts.CancelAsync();
            }
        });
    }

    private static async Task DrainAsync(PocketServeClient client, CancellationToken ct)
    {
        await foreach (var _ in client.StreamChatAsync(Addr, Req(), ct))
        {
            await Task.Yield();
        }
    }

    private static ChatRequest Req() => new("apple-afm", [new WireMessage("user", "test")]);

    private static string Chunk(string content)
        => "data: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"m\","
            + "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"" + content + "\"},\"finish_reason\":null}]}\n\n";

    private sealed class LateHandler(CancellationTokenSource cts) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var stream = new SlowStream(cts.Token);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StreamContent(stream),
            };
        }
    }

    private sealed class SlowStream(CancellationToken ct) : MemoryStream(
        Encoding.UTF8.GetBytes(Chunk("a") + Chunk("b")))
    {
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            ct.ThrowIfCancellationRequested();
            return await base.ReadAsync(buffer, cancellationToken);
        }
    }
}
