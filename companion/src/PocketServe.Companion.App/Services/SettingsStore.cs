namespace PocketServe.Companion.App.Services;

using System.Text.Json;
using PocketServe.Companion.Core;

/// <summary>Last successfully used server address, persisted between runs.</summary>
public sealed record SavedSettings(string Host, int Port);

/// <summary>Best-effort JSON settings file under LocalApplicationData.</summary>
public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
    };

    private readonly string _directory;
    private readonly string _filePath;

    public SettingsStore()
    {
        _directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PocketServe.Companion");
        _filePath = Path.Combine(_directory, "settings.json");
    }

    public SavedSettings? Load()
    {
        try
        {
            return File.Exists(_filePath)
                ? JsonSerializer.Deserialize<SavedSettings>(File.ReadAllText(_filePath), Options)
                : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    public void Save(ServerAddress address)
    {
        try
        {
            Directory.CreateDirectory(_directory);
            File.WriteAllText(_filePath, JsonSerializer.Serialize(new SavedSettings(address.Host, address.Port), Options));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Settings persistence is best-effort; losing it must never break the app.
        }
    }
}
