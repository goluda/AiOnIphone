using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using PocketServe.Companion.App.Services;
using PocketServe.Companion.App.ViewModels;
using PocketServe.Companion.App.Views;
using PocketServe.Companion.Core;

namespace PocketServe.Companion.App;

public partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var http = new HttpClient { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
            desktop.MainWindow = new MainWindow
            {
                DataContext = new MainViewModel(new PocketServeClient(http), new SettingsStore()),
            };
        }

        base.OnFrameworkInitializationCompleted();
    }
}