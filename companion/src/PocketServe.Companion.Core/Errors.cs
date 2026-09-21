namespace PocketServe.Companion.Core;

/// <summary>
/// Client-side failure with a Polish, user-presentable message.
/// Status 0 means "no HTTP response at all" (connection failure).
/// </summary>
public sealed class PocketServeClientException(int status, string userMessage, Exception? inner = null)
    : Exception(userMessage, inner)
{
    public int Status { get; } = status;

    public string UserMessage { get; } = userMessage;

    /// <summary>Server-provided detail wins; otherwise mapped default per status.</summary>
    public static string MapError(int status, string? serverDetail)
        => !string.IsNullOrWhiteSpace(serverDetail)
            ? serverDetail
            : status switch
            {
                400 => "Złe zapytanie.",
                404 => "Nie znaleziono modelu lub endpointu.",
                409 => "Model nie jest gotowy — pobierz i załaduj go na iPhonie.",
                429 => "Serwer zajęty — poczekaj na koniec generowania.",
                >= 500 => "Błąd silnika na iPhonie.",
                _ => "Nieznany błąd serwera.",
            };

    public const string ConnectFailureMessage =
        "Brak połączenia z iPhonem. Sprawdź adres i czy serwer działa.";
}
