using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Styling;
using Avalonia.Themes.Simple;
using Avalonia.Media;
using Avalonia.Controls;

namespace ZteImeiStudio.Windows;

public sealed class App : Application
{
    public override void Initialize() => ConfigureTheme(this);

    public static void ConfigureTheme(Application application)
    {
        application.RequestedThemeVariant = ThemeVariant.Dark;
        application.Styles.Add(new SimpleTheme());
        application.Resources["ThemeAccentColor"] = Color.Parse("#0C89DB");
        application.Resources["ThemeAccentBrush"] = new SolidColorBrush(Color.Parse("#0C89DB"));
        application.Resources["ThemeAccentBrush2"] = new SolidColorBrush(Color.Parse("#3EB6E2"));
        application.Styles.Add(new Style(selector => selector.OfType<TextBox>())
        {
            Setters = { new Setter(TextBox.CornerRadiusProperty, new CornerRadius(8)), new Setter(TextBox.BorderBrushProperty, new SolidColorBrush(Color.Parse("#284761"))) }
        });
        application.Styles.Add(new Style(selector => selector.OfType<ComboBox>())
        {
            Setters = { new Setter(ComboBox.CornerRadiusProperty, new CornerRadius(8)) }
        });
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            desktop.MainWindow = new MainWindow(new WindowsModemService());
        base.OnFrameworkInitializationCompleted();
    }
}
