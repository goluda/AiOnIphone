namespace PocketServe.Companion.Core;

using System.Text;

/// <summary>
/// Incremental Server-Sent Events frame reader. Faithful port of the iOS
/// <c>SSEParser</c> semantics: blank-line-terminated frames, multi-line
/// <c>data:</c> joined with \n, leading single space stripped, <c>:</c>
/// comments and other non-data fields ignored, <c>[DONE]</c> filtered,
/// split-across-feed safe. Newline (0x0A) never occurs inside a multi-byte
/// UTF-8 sequence, so line extraction on raw bytes is decode-safe.
/// </summary>
public sealed class SseReader
{
    private byte[] _buffer = new byte[1024];
    private int _length;

    public IEnumerable<string> Feed(ReadOnlyMemory<byte> buffer)
    {
        EnsureCapacity(_length + buffer.Length);
        buffer.Span.CopyTo(_buffer.AsSpan(_length));
        _length += buffer.Length;

        var payloads = new List<string>();
        List<string>? frameLines = null;
        var consumed = 0;

        while (TryReadLine(consumed, out var line, out var next))
        {
            consumed = next;

            if (line.Length == 0)
            {
                var payload = JoinDataLines(frameLines);
                frameLines = null;
                if (payload is not null)
                {
                    payloads.Add(payload);
                }

                continue;
            }

            if (line[0] != ':')
            {
                (frameLines ??= []).Add(line);
            }
        }

        Compact(consumed);
        return payloads;
    }

    private bool TryReadLine(int from, out string line, out int next)
    {
        var span = _buffer.AsSpan(from, _length - from);
        var newline = span.IndexOf((byte)'\n');
        if (newline < 0)
        {
            line = string.Empty;
            next = from;
            return false;
        }

        var end = newline;
        if (end > 0 && span[end - 1] == (byte)'\r')
        {
            end--;
        }

        line = Encoding.UTF8.GetString(span[..end]);
        next = from + newline + 1;
        return true;
    }

    private void Compact(int consumed)
    {
        if (consumed == 0)
        {
            return;
        }

        Array.Copy(_buffer, consumed, _buffer, 0, _length - consumed);
        _length -= consumed;
    }

    private void EnsureCapacity(int required)
    {
        if (required <= _buffer.Length)
        {
            return;
        }

        var size = _buffer.Length;
        while (size < required)
        {
            size *= 2;
        }

        Array.Resize(ref _buffer, size);
    }

    private static string? JoinDataLines(List<string>? frameLines)
    {
        if (frameLines is not { Count: > 0 })
        {
            return null;
        }

        var dataLines = frameLines
            .Where(line => line.StartsWith("data:", StringComparison.Ordinal))
            .Select(line => line.Length > 5 && line[5] == ' ' ? line[6..] : line[5..])
            .ToList();

        if (dataLines.Count == 0)
        {
            return null;
        }

        var joined = string.Join('\n', dataLines);
        return joined == "[DONE]" ? null : joined;
    }
}
