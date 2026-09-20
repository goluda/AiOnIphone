namespace PocketServe.Companion.App;

using System.Globalization;
using Avalonia.Data.Converters;
using Avalonia.Layout;
using Avalonia.Media;
using PocketServe.Companion.Core;

/// <summary>Bubble background: user gets accent, assistant gets neutral surface.</summary>
public sealed class ChatRoleToBrushConverter : IValueConverter
{
    private static readonly IBrush UserBrush = new SolidColorBrush(Color.Parse("#1F4068"));
    private static readonly IBrush AssistantBrush = new SolidColorBrush(Color.Parse("#2A2D34"));

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is ChatRole.User ? UserBrush : AssistantBrush;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>User bubbles align right, assistant bubbles align left.</summary>
public sealed class ChatRoleToAlignmentConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is ChatRole.User ? HorizontalAlignment.Right : HorizontalAlignment.Left;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>Connection indicator: green dot when connected, gray otherwise.</summary>
public sealed class ConnectedToBrushConverter : IValueConverter
{
    private static readonly IBrush ConnectedBrush = new SolidColorBrush(Color.Parse("#2EA043"));
    private static readonly IBrush DisconnectedBrush = new SolidColorBrush(Color.Parse("#6E7681"));

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is true ? ConnectedBrush : DisconnectedBrush;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
