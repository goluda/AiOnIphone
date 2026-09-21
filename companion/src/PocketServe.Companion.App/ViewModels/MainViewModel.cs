using System.Collections.ObjectModel;
using System.Globalization;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PocketServe.Companion.App.Services;
using PocketServe.Companion.Core;

namespace PocketServe.Companion.App.ViewModels;

public sealed partial class MainViewModel : ViewModelBase, IDisposable
{
    private const int ConnectTimeoutSeconds = 5;

    private readonly PocketServeClient _client;
    private readonly SettingsStore _store;
    private ServerAddress? _address;
    private CancellationTokenSource? _streamCts;

    [ObservableProperty]
    public partial string Host { get; set; } = string.Empty;

    [ObservableProperty]
    public partial string PortText { get; set; } = ServerAddress.DefaultPort.ToString(CultureInfo.InvariantCulture);

    [ObservableProperty]
    public partial bool IsConnected { get; set; }

    [ObservableProperty]
    public partial string StatusText { get; set; } = "Nie połączono";

    [ObservableProperty]
    public partial ObservableCollection<ModelInfo> Models { get; set; } = [];

    [ObservableProperty]
    public partial ModelInfo? SelectedModel { get; set; }

    [ObservableProperty]
    public partial string Draft { get; set; } = string.Empty;

    [ObservableProperty]
    public partial string StreamingText { get; set; } = string.Empty;

    [ObservableProperty]
    public partial string ErrorText { get; set; } = string.Empty;

    [ObservableProperty]
    public partial bool IsStreaming { get; set; }

    public ObservableCollection<ChatMessage> Messages { get; } = [];

    public bool CanConnect => !string.IsNullOrWhiteSpace(Host) && !IsStreaming;

    public bool CanSend => IsConnected && SelectedModel is not null && !IsStreaming
        && !string.IsNullOrWhiteSpace(Draft);

    partial void OnHostChanged(string value) => OnPropertyChanged(nameof(CanConnect));

    partial void OnIsConnectedChanged(bool value) => OnPropertyChanged(nameof(CanSend));

    partial void OnSelectedModelChanged(ModelInfo? value) => OnPropertyChanged(nameof(CanSend));

    partial void OnDraftChanged(string value) => OnPropertyChanged(nameof(CanSend));

    partial void OnIsStreamingChanged(bool value)
    {
        OnPropertyChanged(nameof(CanConnect));
        OnPropertyChanged(nameof(CanSend));
    }

    public MainViewModel(PocketServeClient client, SettingsStore store)
    {
        _client = client;
        _store = store;
        var saved = store.Load();
        if (saved is not null)
        {
            Host = saved.Host;
            PortText = saved.Port.ToString(CultureInfo.InvariantCulture);
        }
    }

    public MainViewModel()
        : this(new PocketServeClient(new HttpClient()), new SettingsStore())
    {
    }

    [RelayCommand]
    private async Task ConnectAsync(CancellationToken outerCt)
    {
        ErrorText = string.Empty;
        if (!ServerAddress.TryParse(Host, PortText, out var address) || address is null)
        {
            ErrorText = "Nieprawidłowy adres serwera.";
            return;
        }

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(outerCt);
        cts.CancelAfter(TimeSpan.FromSeconds(ConnectTimeoutSeconds));
        try
        {
            var health = await _client.GetHealthAsync(address, cts.Token);
            await RefreshModelsCoreAsync(address, cts.Token);
            _address = address;
            IsConnected = true;
            StatusText = $"Połączono ({health.Status})";
            _store.Save(address);
        }
        catch (PocketServeClientException ex)
        {
            DisconnectWith(ex.UserMessage);
        }
        catch (OperationCanceledException)
        {
            DisconnectWith("Przekroczono czas łączenia. Sprawdź adres i czy serwer działa.");
        }
    }

    private void DisconnectWith(string error)
    {
        _streamCts?.Cancel();
        _address = null;
        IsConnected = false;
        StatusText = "Nie połączono";
        Models.Clear();
        SelectedModel = null;
        ErrorText = error;
    }

    [RelayCommand]
    private void Disconnect()
    {
        _streamCts?.Cancel();
        _address = null;
        IsConnected = false;
        StatusText = "Nie połączono";
        Models.Clear();
        SelectedModel = null;
        ErrorText = string.Empty;
    }

    [RelayCommand]
    private async Task RefreshModelsAsync()
    {
        if (_address is not { } address)
        {
            return;
        }

        ErrorText = string.Empty;
        try
        {
            await RefreshModelsCoreAsync(address, CancellationToken.None);
        }
        catch (PocketServeClientException ex)
        {
            ErrorText = ex.UserMessage;
        }
    }

    private async Task RefreshModelsCoreAsync(ServerAddress address, CancellationToken ct)
    {
        var models = await _client.GetModelsAsync(address, ct);
        var previousId = SelectedModel?.Id;
        Models = new ObservableCollection<ModelInfo>(models);
        var preserved = previousId is not null ? models.FirstOrDefault(m => m.Id == previousId) : null;
        SelectedModel = preserved ?? (models.Count > 0 ? models[0] : null);
    }

    [RelayCommand]
    private async Task SendAsync()
    {
        if (!CanSend || _address is not { } address || SelectedModel is not { } model)
        {
            return;
        }

        ErrorText = string.Empty;
        var prompt = Draft.Trim();
        Draft = string.Empty;

        var history = Messages.Select(ToWire).ToList();
        history.Add(new WireMessage("user", prompt));

        var state = new ChatState();
        state.AddUser(prompt);
        Messages.Add(new ChatMessage(ChatRole.User, prompt));

        IsStreaming = true;
        _streamCts = new CancellationTokenSource();
        try
        {
            state.BeginAssistantTurn();
            await foreach (var delta in _client.StreamChatAsync(
                address,
                new ChatRequest(model.Id, history),
                _streamCts.Token))
            {
                state.AppendStreaming(delta);
                var snapshot = state.StreamingText;
                Dispatcher.UIThread.Post(() => StreamingText = snapshot);
            }

            FinalizeTurn(state);
        }
        catch (Exception ex) when (ex is OperationCanceledException or PocketServeClientException)
        {
            if (ex is PocketServeClientException clientEx)
            {
                ErrorText = clientEx.UserMessage;
            }

            FinalizeTurn(state);
        }
        finally
        {
            _streamCts.Dispose();
            _streamCts = null;
            IsStreaming = false;
            StreamingText = string.Empty;
        }
    }

    [RelayCommand]
    private void Stop() => _streamCts?.Cancel();

    private void FinalizeTurn(ChatState state)
    {
        if (state.IsStreaming)
        {
            Messages.Add(state.EndAssistantTurn());
        }
    }

    private static WireMessage ToWire(ChatMessage message)
        => new(message.Role == ChatRole.User ? "user" : "assistant", message.Content);

    public void Dispose()
    {
        _streamCts?.Cancel();
        _streamCts?.Dispose();
        _streamCts = null;
    }
}
