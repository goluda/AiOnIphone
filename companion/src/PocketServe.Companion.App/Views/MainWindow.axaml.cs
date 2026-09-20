using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using PocketServe.Companion.App.ViewModels;

namespace PocketServe.Companion.App.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        AddHandler(KeyDownEvent, OnPreviewKeyDown, RoutingStrategies.Tunnel);
    }

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);
        if (DataContext is MainViewModel vm)
        {
            vm.Messages.CollectionChanged += (_, _) => TranscriptScroll.ScrollToEnd();
            vm.PropertyChanged += (_, args) =>
            {
                if (args.PropertyName == nameof(MainViewModel.StreamingText))
                {
                    TranscriptScroll.ScrollToEnd();
                }
            };
        }
    }

    private void OnPreviewKeyDown(object? sender, KeyEventArgs e)
    {
        if (InputBox is not null && e.Key == Key.Enter && DataContext is MainViewModel vm
            && !e.KeyModifiers.HasFlag(KeyModifiers.Shift) && vm.CanSend)
        {
            vm.SendCommand.Execute(null);
            e.Handled = true;
        }
    }
}