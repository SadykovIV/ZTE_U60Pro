using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.LogicalTree;
using Avalonia.Styling;
using Avalonia.Themes.Simple;
using Avalonia.Threading;
using ZteImeiStudio.Windows;

using var session = HeadlessUnitTestSession.StartNew(typeof(SmokeApp));
await session.Dispatch(() =>
{
    var modem = new FakeModem();
    var window = new MainWindow(modem);
    window.Show();
    Dispatcher.UIThread.RunJobs();

    var suffixField = window.GetLogicalDescendants().OfType<TextBox>()
        .Single(input => input.Watermark == "Суффикс ключа резервной копии вашей прошивки");
    Assert(suffixField.PasswordChar != '\0', "backup suffix is masked");
    modem.Succeed = false;
    suffixField.Text = "synthetic-first-suffix";
    Click(window, button => button.Content?.ToString() == "Выполнить предварительную подготовку модема");
    Dispatcher.UIThread.RunJobs();
    Assert(modem.LastRequest?.Parameters?["backup_key_suffix"] == "synthetic-first-suffix", "entered suffix reaches preparation");
    Assert(string.IsNullOrEmpty(suffixField.Text), "suffix cleared after failed preparation");
    suffixField.Text = "synthetic-second-suffix";
    Click(window, button => button.Content?.ToString() == "Выполнить предварительную подготовку модема");
    Dispatcher.UIThread.RunJobs();
    Assert(modem.LastRequest?.Parameters?["backup_key_suffix"] == "synthetic-second-suffix", "secret field accepts retry");
    modem.Succeed = true;

    var pages = new (string Title, string[] Sections)[]
    {
        ("Подготовка модема", ["Подключение и настройка", "Агент", "Русификация"]),
        ("Launcher", ["Информация о модеме", "Управление VPN"]),
        ("IMEI", ["Смена IMEI", "Бэкапы IMEI"]),
        ("TTL", ["Настройки TTL"]),
        ("VPN", ["Состояние VPN"]),
        ("Приложения", ["Установлено", "Каталог", "Terminal"]),
        ("Администрирование", ["Доступы", "Бэкапы", "Журнал действий"]),
        ("О модеме", ["Об устройстве", "Память", "Диагностика"]),
    };
    foreach (var page in pages)
    {
        Console.Error.WriteLine("UI smoke: " + page.Title);
        Click(window, button => button.Content?.ToString()?.EndsWith("   " + page.Title, StringComparison.Ordinal) == true);
        Dispatcher.UIThread.RunJobs();
        Assert(window.GetLogicalDescendants().OfType<TextBlock>().Any(label => label.Text == page.Title),
            "page " + page.Title);
        foreach (var section in page.Sections)
        {
            if (page.Sections.Length > 1) Click(window, button => button.Content?.ToString() == section);
            Dispatcher.UIThread.RunJobs();
            Assert(window.GetLogicalDescendants().OfType<TextBlock>().Any(label => label.Text == page.Title),
                "section " + page.Title + "/" + section);
        }
    }

    Click(window, button => button.Content?.ToString()?.EndsWith("   IMEI", StringComparison.Ordinal) == true);
    Console.Error.WriteLine("UI smoke: read action");
    Click(window, button => button.Content?.ToString() == "Смена IMEI");
    Click(window, button => button.Content?.ToString() == "Прочитать IMEI");
    Dispatcher.UIThread.RunJobs();
    Assert(modem.LastOperation == ModemOperation.ReadImei, "IMEI button invokes service");
    window.Close();
    Console.WriteLine("PASS Avalonia headless: protected suffix, retry, 8 pages, 18 sections, IMEI service action");
}, CancellationToken.None);

static void Click(MainWindow window, Func<Button, bool> predicate)
{
    var button = window.GetLogicalDescendants().OfType<Button>().FirstOrDefault(predicate)
        ?? throw new Exception("UI button not found");
    button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
}

static void Assert(bool condition, string label)
{
    if (!condition) throw new Exception("UI smoke failed: " + label);
}

public sealed class SmokeApp : Application
{
    public override void Initialize()
    {
        RequestedThemeVariant = ThemeVariant.Dark;
        Styles.Add(new SimpleTheme());
    }
}

internal sealed class FakeModem : IModemService
{
    public ModemOperation? LastOperation { get; private set; }
    public OperationRequest? LastRequest { get; private set; }
    public bool Succeed { get; set; } = true;
    public Task<DeviceSnapshot> GetDeviceSnapshotAsync(CancellationToken ct = default)
        => Task.FromResult(new DeviceSnapshot(false, "Тест без модема"));
    public Task<OperationResult> RunAsync(OperationRequest request, CancellationToken ct = default)
    {
        LastOperation = request.Operation;
        LastRequest = request;
        return Task.FromResult(new OperationResult(Succeed, "Тестовый ответ"));
    }
    public Task<IReadOnlyList<BackupInfo>> ListBackupsAsync(CancellationToken ct = default)
        => Task.FromResult<IReadOnlyList<BackupInfo>>([]);
    public Task<IReadOnlyList<ModemAppInfo>> ListApplicationsAsync(CancellationToken ct = default)
        => Task.FromResult<IReadOnlyList<ModemAppInfo>>([]);
    public Task<IReadOnlyList<LogEntry>> GetLogsAsync(CancellationToken ct = default)
        => Task.FromResult<IReadOnlyList<LogEntry>>([]);
    public Task<ITerminalSession> OpenTerminalAsync(CancellationToken ct = default)
        => throw new InvalidOperationException("Терминал не открывается в тесте без модема.");
}
