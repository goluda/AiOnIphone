namespace PocketServe.Companion.Core;

using System.Text;

/// <summary>Speaker of a chat message.</summary>
public enum ChatRole
{
    User,
    Assistant,
}

/// <summary>A finalized chat message in the transcript.</summary>
public sealed record ChatMessage(ChatRole Role, string Content);

/// <summary>
/// Transcript state machine: user turns are appended immediately, assistant turns are
/// accumulated in <see cref="StreamingText"/> between Begin/End and finalized into Messages.
/// Not thread-safe; callers marshal UI updates themselves.
/// </summary>
public sealed class ChatState
{
    private readonly List<ChatMessage> _messages = [];
    private readonly StringBuilder _streaming = new();

    public IReadOnlyList<ChatMessage> Messages => _messages;

    public string StreamingText => _streaming.ToString();

    public bool IsStreaming { get; private set; }

    public void AddUser(string content)
    {
        _messages.Add(new ChatMessage(ChatRole.User, content));
    }

    public void BeginAssistantTurn()
    {
        if (IsStreaming)
        {
            throw new InvalidOperationException("Assistant turn is already streaming.");
        }

        IsStreaming = true;
        _streaming.Clear();
    }

    public void AppendStreaming(string delta)
    {
        if (!IsStreaming)
        {
            throw new InvalidOperationException("No assistant turn is streaming.");
        }

        _streaming.Append(delta);
    }

    public ChatMessage EndAssistantTurn()
    {
        if (!IsStreaming)
        {
            throw new InvalidOperationException("No assistant turn is streaming.");
        }

        var message = new ChatMessage(ChatRole.Assistant, _streaming.ToString());
        _messages.Add(message);
        _streaming.Clear();
        IsStreaming = false;
        return message;
    }
}
