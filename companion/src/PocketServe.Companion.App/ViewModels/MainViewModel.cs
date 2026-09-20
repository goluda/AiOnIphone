using CommunityToolkit.Mvvm.ComponentModel;

namespace PocketServe.Companion.App.ViewModels;

public partial class MainViewModel : ViewModelBase
{
    [ObservableProperty]
    public partial string Greeting { get; set; } = "Welcome to Avalonia!";
}
