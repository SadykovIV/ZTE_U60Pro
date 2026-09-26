using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.LogicalTree;
using Avalonia.Styling;
using Avalonia.Themes.Simple;
using Avalonia.Threading;
using ZteImeiStudio.Windows;

var previewRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../dist/ui-preview"));
Directory.CreateDirectory(previewRoot);
using var session = HeadlessUnitTestSession.StartNew(typeof(SmokeApp));
await session.Dispatch(() =>
{
    Localization.SetLanguage("ru", persist: false);
    var modem = new FakeModem();
    var window = new MainWindow(modem, persistPreferences: false);
    window.Show();
    Pump();
    Assert(window.Title == "ZTE U60Pro Manager", "new product name");
    var pages = new (string Title, string[] Sections)[]
    {
        ("Подготовка модема", ["Настройка подключения", "Установка агента", "Русификация"]),
        ("Launcher", ["Информация о модеме", "Управление VPN"]),
        ("IMEI", ["Смена IMEI", "Бэкапы IMEI"]),
        ("TTL", ["Настройки TTL"]),
        ("VPN", ["Состояние VPN"]),
        ("Приложения", ["Установлено", "Каталог", "Terminal"]),
        ("Администрирование", ["Доступы", "Бэкапы", "Журнал действий"]),
        ("О модеме", ["Об устройстве", "Память", "Диагностика"]),
    };
    for (var index = 0; index < pages.Length; index++)
    {
        Click(window, button => button.Name == "Navigation" + index);
        Pump();
        Assert(Label(window, pages[index].Title), "page " + pages[index].Title);
        foreach (var section in pages[index].Sections)
        {
            if (pages[index].Sections.Length > 1) Click(window, button => button.Content?.ToString() == section);
            Pump();
            Assert(Label(window, pages[index].Title), "section " + section);
        }
    }
    // Unverified installed software remains removable; it never enters the verified catalog.
    Click(window, b => b.Name == "Navigation5");
    Click(window, b => b.Content?.ToString() == "Установлено");
    Pump();
    Assert(Label(window, "tcpdump · 4.99.4-1"), "installed app remains visible outside verified catalog");
    Click(window, b => b.Content?.ToString() == "Каталог");
    Pump();
    Assert(Label(window, "htop · 3.3.0-1"), "verified htop visible");
    Assert(!Label(window, "tcpdump · 4.99.4-1"), "unverified tcpdump excluded from catalog");
    Capture(window, "ru-catalog.png");
    Click(window, b => b.Content?.ToString() == "Terminal");
    Pump();
    Assert(modem.TerminalOpens == 1, "terminal connects once on first entry and survives tab navigation");
    Capture(window, "ru-terminal.png");
    Click(window, b => b.Name == "RefreshPage");
    Pump();
    Assert(modem.TerminalOpens == 1, "redraw and refresh do not duplicate terminal sessions");
    Click(window, b => b.Content?.ToString() == "Отключить");
    Pump();
    Click(window, b => b.Name == "RefreshPage");
    Pump();
    Assert(modem.TerminalOpens == 1, "manual disconnect is respected after redraw");
    Assert(Label(window, "opkg не установлен"), "opkg installation prerequisite is visible");
    Click(window, b => b.Name == "Navigation0");
    Click(window, b => b.Content?.ToString() == "Настройка подключения");
    Pump();
    Assert(window.GetLogicalDescendants().OfType<Button>().Any(b => b.Name == "key_path_browse"), "SSH key picker exists");
    Assert(window.GetLogicalDescendants().OfType<Button>().Any(b => b.Name == "known_hosts_path_browse"), "known_hosts picker exists");
    Assert(Label(window, "Backup-key suffix"), "public preparation retains owner-provided backup key suffix");
    Capture(window, "ru-preparation.png");
    Click(window, b => b.Content?.ToString() == "ⓘ  О программе");
    Pump();
    var about = window.OwnedWindows.Single();
    Assert(about.GetLogicalDescendants().OfType<Button>().Count(b => b.Tag?.ToString()?.StartsWith("https://", StringComparison.Ordinal) == true) == 3, "About has GitHub, uFactor and UserGate links");
    Capture(about, "ru-about.png");
    about.Close();
    var language = window.GetLogicalDescendants().OfType<ComboBox>().Single(box => box.Name == "LanguagePicker");
    language.SelectedIndex = 1;
    Pump();
    Assert(Label(window, "Modem preparation"), "language switches current page without restart");
    Assert(window.GetLogicalDescendants().OfType<Button>().Any(b => b.Content?.ToString() == "Agent installation"), "English renamed agent submenu");
    Assert(Localization.Translate("ПОКАЗАТЕЛИ  ·  6 из 12") == "METRICS  ·  6 of 12", "dynamic metric count translation");
    Capture(window, "en-preparation.png");
    Click(window, b => b.Name == "Navigation5");
    Click(window, b => b.Content?.ToString() == "Catalog");
    Pump();
    Capture(window, "en-catalog.png");
    Click(window, b => b.Content?.ToString() == "Terminal");
    Pump();
    Assert(modem.TerminalOpens == 2, "reentering terminal reopens after a manual disconnect");
    Capture(window, "en-terminal.png");
    Click(window, b => b.Content?.ToString() == "Disconnect");
    Pump();
    modem.Connected = false;
    Click(window, b => b.Name == "RefreshPage");
    Pump();
    Click(window, b => b.Name == "Navigation0");
    Click(window, b => b.Name == "Navigation5");
    Pump();
    Assert(modem.TerminalOpens == 2, "terminal does not open while disconnected");
    Assert(Label(window, "Connect to the modem over SSH to use the terminal."), "disconnected terminal explanation");
    Click(window, b => b.Content?.ToString() == "ⓘ  About");
    Pump();
    about = window.OwnedWindows.Single();
    Capture(about, "en-about.png");
    about.Close();
    Click(window, b => b.Name == "Navigation0");
    modem.Connected = true;
    modem.DelayNextTerminal = true;
    Click(window, b => b.Name == "RefreshPage");
    Pump();
    Click(window, b => b.Name == "Navigation5");
    Pump();
    Assert(modem.TerminalOpens == 3, "delayed terminal opening started once");
    Click(window, b => b.Content?.ToString() == "Disconnect");
    Pump();
    Assert(modem.TerminalOpenCancellations == 1, "disconnect cancels an in-flight terminal connection");
    window.Close();
    Assert(modem.TerminalDisposals == 2, "terminal sessions disposed");
    Localization.SetLanguage("ru", persist: false);
    Console.WriteLine("PASS Avalonia headless: 8 pages/18 sections, RU/EN, verified catalog, SSH file pickers, About links, terminal lifecycle, 8 previews");
}, CancellationToken.None);
Console.WriteLine("Previews: " + previewRoot);

void Capture(Window window, string name)
{
    Pump();
    using var frame = window.CaptureRenderedFrame() ?? throw new Exception("No rendered headless frame");
    frame.Save(Path.Combine(previewRoot, name));
}
static void Pump() { Dispatcher.UIThread.RunJobs(); AvaloniaHeadlessPlatform.ForceRenderTimerTick(); Dispatcher.UIThread.RunJobs(); }
static bool Label(Window window, string text) => window.GetLogicalDescendants().OfType<TextBlock>().Any(label => label.Text == text);
static void Click(Window window, Func<Button, bool> predicate)
{
    var button = window.GetLogicalDescendants().OfType<Button>().FirstOrDefault(predicate) ?? throw new Exception("UI button not found");
    button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
}
static void Assert(bool condition, string label) { if (!condition) throw new Exception("UI smoke failed: " + label); }

public sealed class SmokeApp : Application
{
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<SmokeApp>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false });
    public override void Initialize() => App.ConfigureTheme(this);
}
internal sealed class FakeModem : IModemService
{
    public bool Connected { get; set; } = true;
    public int TerminalOpens { get; private set; }
    public int TerminalDisposals { get; private set; }
    public bool DelayNextTerminal { get; set; }
    public int TerminalOpenCancellations { get; private set; }
    public Task<DeviceSnapshot> GetDeviceSnapshotAsync(CancellationToken ct = default) => Task.FromResult(new DeviceSnapshot(Connected, Connected ? "Подключено" : "Нет подключения", Model: "ZTE U60 Pro", Firmware: "MU5250 B31", IpAddress: "192.168.0.1", ConnectionMode: Connected ? "SSH" : null));
    public Task<OperationResult> RunAsync(OperationRequest request, CancellationToken ct = default) => Task.FromResult(new OperationResult(true, "Состояние обновлено."));
    public Task<IReadOnlyList<BackupInfo>> ListBackupsAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<BackupInfo>>([]);
    public Task<IReadOnlyList<ModemAppInfo>> ListApplicationsAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<ModemAppInfo>>([
        new("htop", "htop", "3.3.0-1", true, "Процессы, загрузка CPU и использование памяти."),
        new("tcpdump", "tcpdump", "4.99.4-1", true, "Захват пакетов."), new("opkg", "opkg", "2022-02-24-d038e5b6-2", false, "Пакеты")]);
    public Task<IReadOnlyList<LogEntry>> GetLogsAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<LogEntry>>([]);
    public Task<ITerminalSession> OpenTerminalAsync(CancellationToken ct = default)
    {
        TerminalOpens++;
        if (!DelayNextTerminal) return Task.FromResult<ITerminalSession>(new FakeTerminal(() => TerminalDisposals++));
        DelayNextTerminal = false;
        var pending = new TaskCompletionSource<ITerminalSession>();
        ct.Register(() => { TerminalOpenCancellations++; pending.TrySetCanceled(ct); });
        return pending.Task;
    }
}
internal sealed class FakeTerminal(Action disposed) : ITerminalSession
{
    private EventHandler<TerminalDataEventArgs>? _output;
    public event EventHandler<TerminalDataEventArgs>? OutputReceived { add { _output += value; value?.Invoke(this, new("BusyBox v1.36.1 built-in shell (ash)\n/data # ")); } remove { _output -= value; } }
    public bool IsConnected { get; private set; } = true;
    public Task SendAsync(string text, CancellationToken ct = default) => Task.CompletedTask;
    public ValueTask DisposeAsync() { if (IsConnected) { IsConnected = false; disposed(); } return ValueTask.CompletedTask; }
}
