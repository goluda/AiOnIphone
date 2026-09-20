namespace PocketServe.Companion.Core.Tests;

using PocketServe.Companion.Core;
using Shouldly;

[TestFixture]
public sealed class ChatStateTests
{
    [Test]
    public void AddUser_AppendsUserMessage()
    {
        var sut = new ChatState();

        sut.AddUser("cześć");

        sut.Messages.ShouldHaveSingleItem();
        sut.Messages[0].Role.ShouldBe(ChatRole.User);
        sut.Messages[0].Content.ShouldBe("cześć");
        sut.IsStreaming.ShouldBeFalse();
    }

    [Test]
    public void BeginAppendEnd_ProducesAssistantMessage()
    {
        var sut = new ChatState();
        sut.AddUser("pytanie");

        sut.BeginAssistantTurn();
        sut.IsStreaming.ShouldBeTrue();
        sut.AppendStreaming("To ");
        sut.AppendStreaming("jest ");
        sut.AppendStreaming("odpowiedź");
        var finalized = sut.EndAssistantTurn();

        sut.IsStreaming.ShouldBeFalse();
        finalized.Content.ShouldBe("To jest odpowiedź");
        sut.Messages.Count.ShouldBe(2);
        sut.Messages[1].Role.ShouldBe(ChatRole.Assistant);
        sut.Messages[1].Content.ShouldBe("To jest odpowiedź");
        sut.StreamingText.ShouldBe(string.Empty);
    }

    [Test]
    public void EndAssistantTurn_EmptyStream_KeepsPlaceholderBubble()
    {
        var sut = new ChatState();

        sut.BeginAssistantTurn();
        var finalized = sut.EndAssistantTurn();

        finalized.Role.ShouldBe(ChatRole.Assistant);
        sut.Messages.ShouldHaveSingleItem();
        sut.Messages[0].Role.ShouldBe(ChatRole.Assistant);
        sut.Messages[0].Content.ShouldBe(string.Empty);
    }

    [Test]
    public void AppendStreaming_WithoutBegin_ThrowsInvalidOperation()
    {
        var sut = new ChatState();

        Assert.Throws<InvalidOperationException>(() => sut.AppendStreaming("tekst"));
    }

    [Test]
    public void EndAssistantTurn_WithoutBegin_ThrowsInvalidOperation()
    {
        var sut = new ChatState();

        Assert.Throws<InvalidOperationException>(() => sut.EndAssistantTurn());
    }

    [Test]
    public void BeginAssistantTurn_WhileStreaming_ThrowsInvalidOperation()
    {
        var sut = new ChatState();
        sut.BeginAssistantTurn();

        Assert.Throws<InvalidOperationException>(() => sut.BeginAssistantTurn());
    }
}
