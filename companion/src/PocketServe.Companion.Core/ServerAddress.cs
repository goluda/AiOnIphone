namespace PocketServe.Companion.Core;

/// <summary>Normalized address of a PocketServe instance on the LAN.</summary>
public sealed record ServerAddress(string Host, int Port)
{
    public const int DefaultPort = 8080;

    public string BaseUrl => $"http://{Host}:{Port}";

    /// <summary>
    /// Accepts a bare host, a pasted URL (http/https, optional path), and an
    /// optional explicit port that overrides any port found in the host input.
    /// </summary>
    public static bool TryParse(string? hostInput, string? portInput, out ServerAddress? address)
    {
        address = null;
        var host = (hostInput ?? string.Empty).Trim();
        var portText = (portInput ?? string.Empty).Trim();

        if (host.Length == 0)
        {
            return false;
        }

        int? urlPort = null;

        if (host.StartsWith("http", StringComparison.OrdinalIgnoreCase))
        {
            if (!Uri.TryCreate(host, UriKind.Absolute, out var uri)
                || uri is not { Scheme: "http" or "https" }
                || uri.Host.Length == 0)
            {
                return false;
            }

            host = uri.Host;
            urlPort = uri.IsDefaultPort ? null : uri.Port;
        }

        if (!IsValidHost(host))
        {
            return false;
        }

        var port = urlPort ?? DefaultPort;
        if (portText.Length > 0
            && (!int.TryParse(portText, out port) || port is < 1 or > 65535))
        {
            return false;
        }

        address = new ServerAddress(host, port);
        return true;
    }

    private static bool IsValidHost(string host)
        => host.Length > 0 && !host.Contains(' ') && !host.Contains('/') && !host.Contains(':');
}
