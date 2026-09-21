namespace PocketServe.Companion.Core.Tests;

using System.Text;
using PocketServe.Companion.Core;
using Shouldly;

[TestFixture]
public sealed class SseReaderTests
{
    private static IEnumerable<string> FeedAll(SseReader reader, string input)
        => reader.Feed(Encoding.UTF8.GetBytes(input));

    [Test]
    public void Feed_FullFrame_ReturnsPayload()
    {
        var reader = new SseReader();

        var payloads = FeedAll(reader, "data: {\"a\":1}\n\n").ToList();

        payloads.ShouldHaveSingleItem();
        payloads[0].ShouldBe("{\"a\":1}");
    }

    [Test]
    public void Feed_SplitAcrossFeeds_JoinsFrame()
    {
        var reader = new SseReader();
        var bytes = Encoding.UTF8.GetBytes("data: {\"a\":1}\n\n");
        var split = 8;

        var first = reader.Feed(bytes.AsMemory(0, split)).ToList();
        var second = reader.Feed(bytes.AsMemory(split)).ToList();

        first.ShouldBeEmpty();
        second.ShouldHaveSingleItem();
        second[0].ShouldBe("{\"a\":1}");
    }

    [Test]
    public void Feed_MultibyteCharSplitAcrossFeeds_DecodesCorrectly()
    {
        var reader = new SseReader();
        var bytes = Encoding.UTF8.GetBytes("data: żółw\n\n");
        // Split inside the first multi-byte char ('ż' = 2 bytes, 0xC5 0xBC).
        var prefix = Encoding.UTF8.GetBytes("data: ");
        var split = prefix.Length + 1; // mid-ż

        var first = reader.Feed(bytes.AsMemory(0, split)).ToList();
        var second = reader.Feed(bytes.AsMemory(split)).ToList();

        first.ShouldBeEmpty();
        second.ShouldHaveSingleItem();
        second[0].ShouldBe("żółw");
    }

    [Test]
    public void Feed_MultipleFramesInOneFeed_ReturnsBoth()
    {
        var reader = new SseReader();

        var payloads = FeedAll(reader, "data: one\n\ndata: two\n\n").ToList();

        payloads.ShouldBe(["one", "two"]);
    }

    [Test]
    public void Feed_CommentLine_Ignored()
    {
        var reader = new SseReader();

        var payloads = FeedAll(reader, ": keep-alive\ndata: x\n\n").ToList();

        payloads.ShouldHaveSingleItem();
        payloads[0].ShouldBe("x");
    }

    [Test]
    public void Feed_EventAndIdFields_Ignored()
    {
        var reader = new SseReader();

        var payloads = FeedAll(reader, "event: message\nid: 42\ndata: x\n\n").ToList();

        payloads.ShouldHaveSingleItem();
        payloads[0].ShouldBe("x");
    }

    [Test]
    public void Feed_MultiLineData_JoinedWithNewline()
    {
        var reader = new SseReader();

        var payloads = FeedAll(reader, "data: a\ndata: b\n\n").ToList();

        payloads.ShouldHaveSingleItem();
        payloads[0].ShouldBe("a\nb");
    }

    [Test]
    public void Feed_DoneMarker_Filtered()
    {
        var reader = new SseReader();

        var payloads = FeedAll(reader, "data: [DONE]\n\n").ToList();

        payloads.ShouldBeEmpty();
    }

    [Test]
    public void Feed_Crlf_ParsesSameAsLf()
    {
        var reader = new SseReader();

        var payloads = FeedAll(reader, "data: hello\r\n\r\n").ToList();

        payloads.ShouldHaveSingleItem();
        payloads[0].ShouldBe("hello");
    }

    [Test]
    public void Feed_OnlyDataColonNoSpace_YieldsEmptyString()
    {
        var reader = new SseReader();

        var payloads = FeedAll(reader, "data:\n\n").ToList();

        payloads.ShouldHaveSingleItem();
        payloads[0].ShouldBe(string.Empty);
    }
}
