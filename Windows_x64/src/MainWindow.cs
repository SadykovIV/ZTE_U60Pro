using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Avalonia.Media.Imaging;
using System.Diagnostics;
using ZteImeiStudio.Windows.Core;
using ZteImeiStudio.Windows.Esim;

namespace ZteImeiStudio.Windows;

public sealed partial class MainWindow : Window
{
    private sealed record Page(string Title, string Subtitle, string Icon, string[] Sections);
    private sealed record DisplayMetric(string Id, string Title, string Detail, string TileTitle, string Example);

    private static readonly DisplayMetric[] DisplayMetrics =
    [
        new("cpu", "Загрузка процессора", "Доля занятого времени CPU", "CPU", "24 %"),
        new("signal", "Уровень сигнала", "Мощность радиосигнала", "Сигнал", "−87 dBm"),
        new("network", "Тип сети", "2G, 3G, LTE или 5G", "Соединение", "5G NSA"),
        new("carriers", "Активные несущие", "Количество и диапазоны активных несущих", "Несущие", "B3 + B7 + n78"),
        new("cpu_temp", "Температура процессора", "Максимальная температура CPU", "Темп. CPU", "48 °C"),
        new("modem_temp", "Температура модема", "Температура модемной части", "Темп. модема", "43 °C"),
        new("memory", "Оперативная память", "Занятая и общая память", "Память", "284 / 512 МиБ"),
        new("storage", "Хранилище /data", "Занятый и общий объём", "Хранилище", "1,2 / 3,5 ГиБ"),
        new("uptime", "Время работы", "Время с последней загрузки", "Время работы", "2 д 03:04:05"),
        new("battery", "Заряд батареи", "Остаток заряда", "Батарея", "82 %"),
        new("rsrq", "Качество сигнала RSRQ", "Качество радиосигнала", "RSRQ", "−10 dB"),
        new("sinr", "Сигнал / помехи SINR", "Отношение сигнала к помехам", "SINR", "18 dB"),
    ];
    private static readonly DataFormat<string> MetricDragFormat =
        DataFormat.CreateStringApplicationFormat("zte-launcher-metric");

    private static readonly Page[] Pages =
    [
        new("Подготовка модема", "Подключение, агент и русский интерфейс", "⌁", ["Настройка подключения", "Диагностика", "Установка агента", "Русификация"]),
        new("Launcher", "Экран модема и его плитки", "▣", ["Информация о модеме", "Управление VPN"]),
        new("IMEI", "Чтение, смена и резервные копии", "◈", ["Смена IMEI", "Бэкапы IMEI"]),
        new("TTL", "Правила исходящего и входящего TTL", "⇄", ["Настройки TTL"]),
        new("VPN", "Компоненты VPN на модеме", "◇", ["Состояние VPN"]),
        new("Приложения", "Установленные пакеты и каталог", "▦", ["Установлено", "Каталог", "Terminal"]),
        new("Администрирование", "Доступы, бэкапы и журнал", "⚙", ["Доступы", "Бэкапы", "Журнал действий"]),
        new("О модеме", "Устройство и память", "ⓘ", ["Об устройстве", "Память"]),
        new("eSIM", "Профили физической eUICC", "▣", ["Профили"]),
    ];

    private static readonly IBrush Canvas = Brush("#081528");
    private static readonly IBrush Sidebar = Brush("#0B1B30");
    private static readonly IBrush Surface = Brush("#10243D");
    private static readonly IBrush Elevated = Brush("#193650");
    private static readonly new IBrush Foreground = Brush("#EAF3FC");
    private static readonly IBrush Secondary = Brush("#9BAFC5");
    private static readonly IBrush Accent = Brush("#0C89DB");
    private static readonly IBrush Warn = Brush("#E9B86D");

    private readonly IModemService _service;
    private readonly StackPanel _sidebarItems = new() { Spacing = 6 };
    private readonly TextBlock _pageTitle = new() { Foreground = Foreground, FontSize = 30, FontWeight = FontWeight.Bold };
    private readonly TextBlock _pageSubtitle = new() { Foreground = Secondary, FontSize = 13, TextWrapping = TextWrapping.Wrap };
    private readonly Button _aboutButton = new();
    private readonly TextBlock _sidebarCaption = new() { Foreground = Secondary, FontSize = 11, TextWrapping = TextWrapping.Wrap };
    private bool _terminalOpening;
    private CancellationTokenSource? _terminalOpenCancellation;
    private bool _terminalAutoAttempted;
    private readonly StackPanel _body = new() { Spacing = 18 };
    private readonly TextBlock _status = new() { Foreground = Secondary, FontSize = 12 };
    private readonly TextBlock _connection = new() { Foreground = Accent, FontSize = 12 };
    private readonly TextBlock _sidebarConnection = new() { Foreground = Warn, FontSize = 12, TextWrapping = TextWrapping.Wrap };
    private readonly List<Button> _actionButtons = [];
    private Button? _refreshButton;
    private Button? _preparationButton;
    private Button? _cancelCleanupButton;
    private CheckBox? _skipFirmwareCheckBox;
    private CheckBox? _forcePreparationCheckBox;
    private CheckBox? _cleanPreparationCheckBox;
    private readonly Dictionary<string, string> _form = new(StringComparer.Ordinal);
    private readonly Dictionary<string, TextBox> _secretFields = new(StringComparer.Ordinal);
    // Preparation credentials belong to this window and selected target only. Never persist them.
    private readonly Dictionary<string, string> _preparationSecrets = new(StringComparer.Ordinal);
    private static bool IsPreparationSecret(string key) => key is "web_password" or "agent_password" or "backup_key_suffix";
    private StackPanel? _metricRows;
    private StackPanel? _previewRows;
    private TextBlock? _metricCount;
    private readonly int[] _sections = new int[Pages.Length];
    private readonly CancellationTokenSource _lifetime = new();
    private IReadOnlyList<BackupInfo> _backups = [];
    private IReadOnlyList<ModemAppInfo> _applications = [];
    private IReadOnlyList<LogEntry> _logs = [];
    private DeviceSnapshot? _snapshot;
    private ITerminalSession? _terminal;
    private SelectableTextBlock? _terminalOutput;
    private ScrollViewer? _terminalViewport;
    private bool _terminalFollowOutput = true;
    private TextBox? _terminalInput;
    private string _terminalText = "";
    private bool _busy;
    private int _page;

    public MainWindow(IModemService service, bool persistPreferences = true)
    {
        _service = service;
        Title = "ZTE U60Pro Manager";
        Width = 1220;
        Height = 860;
        MinWidth = 980;
        MinHeight = 680;
        Background = Canvas;
        FontFamily = new FontFamily("Segoe UI, Inter, sans-serif");
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Resources", "Branding", "manager-icon.png");
        if (File.Exists(iconPath)) Icon = new WindowIcon(iconPath);

        var layout = new Grid { ColumnDefinitions = new ColumnDefinitions("250,*") };
        var side = new Border { Background = Sidebar, BorderBrush = Elevated, BorderThickness = new Thickness(0, 0, 1, 0), Padding = new Thickness(16, 25, 16, 16) };
        var sideLayout = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        var brand = new StackPanel { Spacing = 10, Margin = new Thickness(9, 0, 0, 26) };
        var brandRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 11 };
        if (File.Exists(iconPath)) brandRow.Children.Add(new Image { Source = new Bitmap(iconPath), Width = 44, Height = 44 });
        else brandRow.Children.Add(new TextBlock { Text = "▂▄▆█", Foreground = Accent, FontSize = 23, VerticalAlignment = VerticalAlignment.Center });
        var brandText = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        brandText.Children.Add(new TextBlock { Text = "ZTE U60Pro", Foreground = Foreground, FontSize = 19, FontWeight = FontWeight.Bold });
        brandText.Children.Add(new TextBlock { Text = "MANAGER", Foreground = Secondary, FontSize = 11, LetterSpacing = 2 });
        brandRow.Children.Add(brandText);
        brand.Children.Add(brandRow);
        sideLayout.Children.Add(brand);
        var navigation = new ScrollViewer { Content = _sidebarItems, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        Grid.SetRow(navigation, 1);
        sideLayout.Children.Add(navigation);
        var sideBottom = new StackPanel { Spacing = 12, Margin = new Thickness(7, 20, 7, 0) };
        sideBottom.Children.Add(new Border { Height = 1, Background = Elevated, Margin = new Thickness(0, 0, 0, 5) });
        sideBottom.Children.Add(_sidebarConnection);
        sideBottom.Children.Add(_sidebarCaption);
        var language = new ComboBox
        {
            Name = "LanguagePicker", ItemsSource = new[] { "Русский", "English" },
            SelectedIndex = Localization.IsEnglish ? 1 : 0, HorizontalAlignment = HorizontalAlignment.Stretch,
            Background = Surface, Foreground = Foreground,
        };
        language.SelectionChanged += (_, _) =>
        {
            Localization.SetLanguage(language.SelectedIndex == 1 ? "en" : "ru", persist: persistPreferences);
            RenderSidebar(); RenderPage(); UpdateConnectionLabels();
            SetStatus("Язык интерфейса изменён.");
        };
        sideBottom.Children.Add(language);
        _aboutButton.Background = Brushes.Transparent;
        _aboutButton.Foreground = Secondary;
        _aboutButton.BorderThickness = new Thickness(0);
        _aboutButton.Padding = new Thickness(0, 7);
        _aboutButton.HorizontalAlignment = HorizontalAlignment.Stretch;
        _aboutButton.HorizontalContentAlignment = HorizontalAlignment.Left;
        _aboutButton.Click += async (_, _) => await ShowAboutAsync();
        sideBottom.Children.Add(_aboutButton);
        Grid.SetRow(sideBottom, 2);
        sideLayout.Children.Add(sideBottom);
        side.Child = sideLayout;
        layout.Children.Add(side);

        var right = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        Grid.SetColumn(right, 1);
        var headerBorder = new Border { BorderBrush = Elevated, BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(30, 28, 30, 25) };
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 15 };
        var titleStack = new StackPanel { Spacing = 7 };
        titleStack.Children.Add(_pageTitle);
        titleStack.Children.Add(_pageSubtitle);
        header.Children.Add(titleStack);
        var headerActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        headerActions.Children.Add(new Border
        {
            Child = new TextBlock { Text = "WINDOWS · X64", Foreground = Secondary, FontSize = 11, FontWeight = FontWeight.SemiBold, LetterSpacing = 1 },
            CornerRadius = new CornerRadius(20), BorderBrush = Elevated, BorderThickness = new Thickness(1), Padding = new Thickness(15, 9),
        });
        var refresh = ActionButton("↻", async () => await RefreshAsync(reconnectConfigured: true), false);
        refresh.Name = "RefreshPage";
        ToolTip.SetTip(refresh, Localization.Translate("Обновить"));
        refresh.Margin = new Thickness(0);
        _refreshButton = refresh;
        headerActions.Children.Add(refresh);
        Grid.SetColumn(headerActions, 1);
        header.Children.Add(headerActions);
        headerBorder.Child = header;
        right.Children.Add(headerBorder);
        var scroller = new ScrollViewer
        {
            Content = _body,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        };
        _body.Margin = new Thickness(30, 26, 30, 30);
        Grid.SetRow(scroller, 1);
        right.Children.Add(scroller);
        var footer = new Border { Background = Sidebar, BorderBrush = Elevated, BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(30, 11) };
        _status.Text = Localization.Translate("Готово к подключению");
        _status.TextWrapping = TextWrapping.Wrap;
        footer.Child = _status;
        Grid.SetRow(footer, 2);
        right.Children.Add(footer);
        layout.Children.Add(right);
        Content = layout;

        var connection = _service.GetConnectionSettings();
        _form["host"] = connection.Host;
        _form["port"] = connection.Port.ToString(System.Globalization.CultureInfo.InvariantCulture);
        _form["username"] = connection.Username;
        _form["key_path"] = connection.KeyPath;
        _form["known_hosts_path"] = connection.KnownHostsPath;
        _form["mode"] = "SSH";
        _form["outbound_ttl"] = "64";
        _form["incoming_delta"] = "1";
        _form["style"] = "list";
        _form["metrics"] = "cpu,signal,network,carriers,cpu_temp,modem_temp";
        _form["metric_order"] = string.Join(',', DisplayMetrics.Select(metric => metric.Id));
        _form["password_mode"] = "main";
        _form["ssid"] = "ZTE-VPN";
        RenderSidebar();
        RenderPage();
        UpdateConnectionLabels();
        VerifiedCatalogStore.Shared.Changed += CatalogChanged;
        Opened += async (_, _) => { _researchReport = await _service.GetFirmwareResearchAsync(_lifetime.Token); await RefreshAsync(); };
        Closed += async (_, _) => await ShutdownAsync();
    }

    private static IBrush Brush(string hex) => new SolidColorBrush(Color.Parse(hex));

    private void RenderSidebar()
    {
        _sidebarItems.Children.Clear();
        _aboutButton.Content = "ⓘ  " + Localization.Translate("О программе");
        _sidebarCaption.Text = Localization.Translate("Локальное управление модемом");
        for (var i = 0; i < Pages.Length; i++)
        {
            var index = i;
            var selected = i == _page;
            var button = new Button
            {
                Content = NavigationLabel(i, selected),
                Name = "Navigation" + i,
                CornerRadius = new CornerRadius(10),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = selected ? Elevated : Brushes.Transparent,
                Foreground = selected ? Accent : Foreground,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(12, 11),
                FontSize = 13,
            };
            button.Click += async (_, _) =>
            {
                if (_page != index) _terminalAutoAttempted = false;
                _page = index;
                RenderSidebar();
                RenderPage();
                await LoadPageDataAsync();
            };
            _sidebarItems.Children.Add(button);
        }
    }

    private static Control NavigationLabel(int index, bool selected)
    {
        string[] paths = [
            "M15 3 L19 7 M12 6 L6 12 M5 11 L3 13 L7 17 L9 15 M11 13 L17 19 L20 16 L14 10 M13 5 L16 2 L21 7 L18 10",
            "M3 4 H21 V17 H3 Z M8 21 H16 M12 17 V21",
            "M6 2 H14 L19 7 V22 H6 Z M9 10 H16 V18 H9 Z M12 10 V18 M9 14 H16",
            "M3 6 H21 M3 12 H21 M3 18 H21 M8 3 V9 M16 9 V15 M10 15 V21",
            "M12 2 A10 10 0 1 0 12 22 A10 10 0 1 0 12 2 M2 12 H22 M12 2 C6 7 6 17 12 22 M12 2 C18 7 18 17 12 22",
            "M3 3 H9 V9 H3 Z M15 3 H21 V9 H15 Z M3 15 H9 V21 H3 Z M15 15 H21 V21 H15 Z",
            "M9 4 A4 4 0 1 0 9 12 A4 4 0 1 0 9 4 M2 21 C2 12 16 12 16 21 M20 13 A3 3 0 1 0 20 19 M18 19 V23 M18 21 H21",
            "M3 10 H21 V20 H3 Z M7 15 H8 M11 15 H12 M17 10 V5 M12 2 C16 0 20 2 22 5 M13 5 C15 4 17 5 18 7",
            "M6 2 H14 L19 7 V22 H6 Z M9 10 H16 V18 H9 Z M12 10 V18 M9 14 H16"
        ];
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(new Avalonia.Controls.Shapes.Path { Data = Geometry.Parse(paths[index]), Width = 18, Height = 18,
            Stretch = Stretch.Uniform, Stroke = selected ? Accent : Secondary, StrokeThickness = 1.7, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock { Text = Localization.Translate(Pages[index].Title), Foreground = selected ? Accent : Foreground, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        return row;
    }

    private static Control FieldPair(Control first, Control second)
    {
        var columns = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*"), ColumnSpacing = 18 };
        columns.Children.Add(first);
        Grid.SetColumn(second, 1);
        columns.Children.Add(second);
        return columns;
    }

    private void RenderPage()
    {
        _body.Children.Clear();
        _metricRows = null;
        _previewRows = null;
        _metricCount = null;
        ClearSecrets(discardFields: true, preservePreparation: true);
        _actionButtons.Clear();
        _preparationButton = null;
        _cancelCleanupButton = null;
        _skipFirmwareCheckBox = null;
        _forcePreparationCheckBox = null;
        _cleanPreparationCheckBox = null;
        _researchCollectButton = null;
        _firmwareAdaptationButton = null;
        _chooseCustomAgentButton = null; _installCustomAgentButton = null;
        _diagnosticAccessButton = null;
        _refreshAdbButton = null;
        _verifyBackupKeyButton = null;
        _backupKeyCheckStatus = null;
        _adbEnabledCheckbox = null;
        _diagnosticConnectionStatus = null;
        _diagnosticAccessStatus = null;
        _researchProgress = null;
        if (_refreshButton is not null) _actionButtons.Add(_refreshButton);
        var page = Pages[_page];
        _pageTitle.Text = Localization.Translate(page.Title);
        _pageSubtitle.Text = Localization.Translate(page.Subtitle);
        if (page.Sections.Length > 1)
        {
            var tabs = new WrapPanel { ItemHeight = 36, Orientation = Orientation.Horizontal };
            for (var i = 0; i < page.Sections.Length; i++)
            {
                var section = i;
                var tab = new Button
                {
                    Name = "Section" + _page + "-" + i,
                    Content = Localization.Translate(page.Sections[i]),
                    CornerRadius = new CornerRadius(8),
                    Background = i == _sections[_page] ? Accent : Surface,
                    Foreground = i == _sections[_page] ? Brushes.White : Secondary,
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(12, 8),
                    Margin = new Thickness(0, 0, 6, 6),
                };
                tab.Click += async (_, _) =>
                {
                    if (_sections[_page] != section) _terminalAutoAttempted = false;
                    _sections[_page] = section;
                    RenderPage();
                    await LoadPageDataAsync();
                };
                tabs.Children.Add(tab);
            }
            _body.Children.Add(tabs);
        }
        switch (_page)
        {
            case 0: BuildPreparation(); break;
            case 1: BuildLauncher(); break;
            case 2: BuildImei(); break;
            case 3: BuildTtl(); break;
            case 4: BuildVpn(); break;
            case 5: BuildApplications(); break;
            case 6: BuildAdministration(); break;
            case 7: BuildModem(); break;
            case 8: BuildEsim(); break;
        }
    }

    private void BuildPreparation()
    {
        switch (_sections[0])
        {
            case 0:
                AddCard("Подключение к модему", Localization.IsEnglish ? "Manage the modem over SSH. USB ADB is used only to prepare SSH access." : "Управление модемом выполняется по SSH. USB ADB используется только для подготовки доступа SSH.", panel =>
                {
                    panel.Children.Add(FieldPair(Field("Адрес модема", "host", "192.168.0.1"), Field("Пользователь SSH", "username", "root")));
                    panel.Children.Add(FileField("Приватный ключ SSH", "key_path", "Использовать локальный ключ"));
                    panel.Children.Add(FileField("Файл known_hosts", "known_hosts_path", "Использовать локальный known_hosts"));
                    var skipFirmware = new CheckBox
                    {
                        Name = "SkipFirmwareCheck", IsChecked = Get("skip_firmware_check") == "true",
                        Content = Localization.Translate("Не проверять версию прошивки"), Foreground = Foreground,
                        IsEnabled = !_busy && _terminal?.IsConnected != true && !_terminalOpening,
                    };
                    _skipFirmwareCheckBox = skipFirmware;
                    skipFirmware.IsCheckedChanged += (_, _) =>
                    {
                        if (!ReferenceEquals(_skipFirmwareCheckBox, skipFirmware) || _busy || _terminal?.IsConnected == true || _terminalOpening) return;
                        _form["skip_firmware_check"] = skipFirmware.IsChecked == true ? "true" : "false";
                    };
                    panel.Children.Add(skipFirmware);
                    panel.Children.Add(Muted("Снимает общую сверку прошивки с B31 для подготовки и операций по SSH. Проверки устройства, подключения, архитектуры и файлов сохраняются; специальные требования компонентов остаются."));
                    panel.Children.Add(Actions(("Подключиться", ModemOperation.Connect, ["host", "username", "key_path", "known_hosts_path", "skip_firmware_check"])));
                    BuildConnectionMethods(panel);
                    var force = new CheckBox
                    {
                        Name = "ForcePreparation", IsChecked = Get("force_reinstall") == "true",
                        Content = Localization.Translate("Принудительная подготовка: переустановить агент и SSH"),
                        Foreground = Foreground, IsEnabled = CanChangePreparationMode(),
                    };
                    _forcePreparationCheckBox = force;
                    force.IsCheckedChanged += (_, _) =>
                    {
                        if (!ReferenceEquals(_forcePreparationCheckBox, force) || _busy || _terminal?.IsConnected == true || _terminalOpening) return;
                        _form["force_reinstall"] = force.IsChecked == true ? "true" : "false";
                        if (force.IsChecked != true)
                        {
                            _form["clean_components"] = "false";
                            if (_cleanPreparationCheckBox is not null) _cleanPreparationCheckBox.IsChecked = false;
                        }
                        if (_preparationButton is not null) _preparationButton.IsEnabled = CanPrepare();
                    };
                    panel.Children.Add(force);
                    panel.Children.Add(Muted("Сначала сохраняется резервная копия. Агент получит введённый пароль; временные файлы удаляются после проверки. Незавершённая операция продолжается в сохранённом режиме."));
                    var clean = new CheckBox
                    {
                        Name = "CleanPreparation", IsChecked = Get("clean_components") == "true",
                        Content = Localization.Translate("Чистая установка после заводского сброса"),
                        Foreground = Foreground, IsEnabled = CanSelectCleanPreparation(),
                    };
                    _cleanPreparationCheckBox = clean;
                    clean.IsCheckedChanged += (_, _) =>
                    {
                        if (!ReferenceEquals(_cleanPreparationCheckBox, clean) || !CanSelectCleanPreparation()) return;
                        _form["clean_components"] = clean.IsChecked == true ? "true" : "false";
                        if (clean.IsChecked == true)
                        {
                            _form["force_reinstall"] = "true";
                            force.IsChecked = true;
                        }
                        if (_preparationButton is not null) _preparationButton.IsEnabled = CanPrepare();
                    };
                    var cleanRow = new WrapPanel { Orientation = Orientation.Horizontal };
                    cleanRow.Children.Add(clean);
                    var cleanInfo = OperationInfoButton(OperationHelpContent.CleanPreparation);
                    cleanInfo.Name = "CleanPreparationInfo";
                    cleanRow.Children.Add(cleanInfo);
                    var preparation = new WrapPanel { Orientation = Orientation.Horizontal };
                    _preparationButton = ActionButton(_snapshot?.ComponentCleanupPending == true ? "Продолжить очистку компонентов" : "Выполнить предварительную подготовку модема", async () =>
                        await ExecuteAsync(ModemOperation.PrepareSsh, ["host", "username", "web_password", "agent_password", "backup_key_suffix", "skip_firmware_check", "key_path", "known_hosts_path", "force_reinstall", "clean_components"]), true);
                    _preparationButton.IsEnabled = CanPrepare();
                    preparation.Children.Add(_preparationButton);
                    if (_snapshot?.ComponentCleanupPending == true)
                    {
                        _cancelCleanupButton = ActionButton("Отменить очистку", async () => await ExecuteAsync(ModemOperation.CancelComponentCleanup, ["host", "username", "key_path", "known_hosts_path"]), false);
                        _cancelCleanupButton.IsEnabled = CanPrepare();
                        preparation.Children.Add(_cancelCleanupButton);
                    }

                    preparation.Children.Add(cleanRow);
                    preparation.Children.Add(OperationInfoButton(OperationHelpContent.Preparation));
                    panel.Children.Add(preparation);
                });
                AddSnapshotCard();
                break;
            case 1:
                BuildDiagnostics();
                break;
            case 2:
                AddCard("Агент модема", "Постоянная установка агента eSIM и веб-панели.", panel =>
                {
                    panel.Children.Add(Actions(
                        ("Проверить агент", ModemOperation.RefreshAgent, null),
                        ("Установить / обновить", ModemOperation.InstallAgent, null),
                        ("Восстановить предыдущий", ModemOperation.RestoreAgent, null)));
                    panel.Children.Add(Muted("Версия в комплекте: " + AgentPackage.Version));
                    panel.Children.Add(Muted("После перезагрузки агент и веб-панель остаются на модеме. Восстановление предыдущего агента меняет только его исполняемый файл; ручной откат панели не поддерживается."));
                    panel.Children.Add(ValueLine("Состояние", _snapshot?.Agent));
                });
                BuildCustomAgent();
                break;
            case 3:
                AddCard("Русский интерфейс", "Пакет русификации экрана устанавливается на модем.", panel =>
                {
                    panel.Children.Add(Actions(
                        ("Проверить", ModemOperation.RefreshLocalization, null),
                        ("Установить", ModemOperation.InstallLocalization, null),
                        ("Восстановить предыдущий", ModemOperation.RestoreLocalization, null)));
                    panel.Children.Add(ValueLine("Состояние", _snapshot?.ScreenLocalization));
                });
                break;
        }
    }

    private void BuildLauncher()
    {
        AddCard("Плитки на экране модема", "Выбор и порядок дополнительных страниц: информация, VPN и eSIM.", panel =>
        {
            panel.Children.Add(ValueLine("Состояние", _snapshot?.Launcher));
            panel.Children.Add(Actions(("Проверить лаунчер", ModemOperation.RefreshLauncher, null)));
            BuildLauncherPageEditor(panel);
        });
        if (_sections[1] == 0)
        {
            AddCard("Информация о модеме", "Выберите показатели и перетащите их за ручку справа, чтобы изменить порядок на экране модема.",
                BuildLauncherInfoEditor);
        }
        else
        {
            AddCard("Управление VPN", "Состояние сети и профилей на странице лаунчера.", BuildLauncherVpnPreview);
            AddCard("Wi-Fi с VPN", "Название сети и режим пароля для плитки VPN на экране модема.", panel =>
            {
                panel.Children.Add(Actions(("Прочитать настройки", ModemOperation.RefreshVpnWifi, null)));
                panel.Children.Add(Field("Название сети (SSID)", "ssid", "ZTE-VPN"));
                panel.Children.Add(Muted("Не более 32 байт UTF-8; одно имя для 2,4 и 5 ГГц."));
                panel.Children.Add(Muted("Режим пароля"));
                var passwordModes = new ComboBox
                {
                    ItemsSource = new[] { "Пароль основной сети", "Новый пароль", "Сохранить текущий" }.Select(Localization.Translate).ToArray(),
                    SelectedIndex = Get("password_mode") switch { "custom" => 1, "preserve" => 2, _ => 0 },
                    MinWidth = 240,
                    HorizontalAlignment = HorizontalAlignment.Left,
                };
                passwordModes.SelectionChanged += (_, _) => _form["password_mode"] = passwordModes.SelectedIndex switch
                {
                    1 => "custom", 2 => "preserve", _ => "main",
                };
                panel.Children.Add(passwordModes);
                panel.Children.Add(Field("Новый пароль (режим custom)", "custom_password", "Пароль", secret: true));
                panel.Children.Add(Field("Повторите пароль", "confirm_password", "Повторите", secret: true));
                panel.Children.Add(ActionButton("Сохранить настройки сети", async () =>
                {
                    var ssid = Get("ssid");
                    var mode = Get("password_mode").ToLowerInvariant();
                    if (ssid.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(ssid) > 32)
                    {
                        SetStatus("SSID должен содержать от 1 до 32 байт UTF-8.", true);
                        return;
                    }
                    if (mode is not ("main" or "custom" or "preserve"))
                    {
                        SetStatus("Режим пароля: main, custom или preserve.", true);
                        return;
                    }
                    if (mode == "custom" && Get("custom_password") != Get("confirm_password"))
                    {
                        SetStatus("Пароли не совпадают.", true);
                        return;
                    }
                    if (mode == "custom" && Get("custom_password").Length is < 8 or > 63)
                    {
                        SetStatus("Пароль Wi-Fi должен содержать от 8 до 63 символов.", true);
                        return;
                    }
                    await ExecuteAsync(ModemOperation.SaveVpnWifi, ["ssid", "password_mode", "custom_password", "confirm_password"]);
                }, true));
            });
        }
    }

    private void BuildLauncherVpnPreview(StackPanel panel)
    {
        var vpn = _snapshot?.VpnPage;
        var columns = new Grid { ColumnDefinitions = new ColumnDefinitions("*,260") };
        var status = new StackPanel { Spacing = 12 };
        status.Children.Add(Muted("На экране модема можно включить Wi-Fi с VPN и выбрать профиль. Смена профиля переподключает VPN."));
        if (vpn is null)
            status.Children.Add(Muted("Проверьте VPN, чтобы увидеть установленные компоненты и профили."));
        else
        {
            status.Children.Add(ValueLine("Компоненты VPN", vpn.ComponentsReady ? "Готовы" :
                vpn.Installed ? "Требуют обновления" : "Не установлены"));
            status.Children.Add(ValueLine("Wi-Fi с VPN", vpn.Enabled ? "Включён" : "Выключен"));
            status.Children.Add(ValueLine("Профили", vpn.Profiles.Count.ToString()));
            if (!string.IsNullOrWhiteSpace(vpn.ActiveProfile))
                status.Children.Add(ValueLine("Активный профиль", vpn.ActiveProfile));
        }
        status.Children.Add(Actions(("Обновить состояние VPN", ModemOperation.RefreshVpn, null)));
        status.Children.Add(Muted("Импорт и параметры профилей задаются в панели агента модема. На экране появятся те же профили."));
        columns.Children.Add(status);

        var previewColumn = new StackPanel { Spacing = 9, Margin = new Thickness(18, 0, 0, 0) };
        previewColumn.Children.Add(new TextBlock
        {
            Text = Localization.Translate("ПРЕДПРОСМОТР ЭКРАНА"), Foreground = Secondary,
            FontSize = 10, FontWeight = FontWeight.SemiBold,
        });
        var screen = new StackPanel { Spacing = 8, Margin = new Thickness(11) };
        screen.Children.Add(new TextBlock
        {
            Text = "VPN", Foreground = Foreground, FontSize = 21,
            FontWeight = FontWeight.SemiBold,
        });
        screen.Children.Add(new TextBlock
        {
            Text = Localization.Translate(vpn is null ? "SSID не прочитан" :
                string.IsNullOrWhiteSpace(vpn.Ssid) ? "Сеть не настроена" : vpn.Ssid),
            Foreground = Secondary, FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        screen.Children.Add(VpnPreviewRow("Wi-Fi с VPN", vpn?.Enabled == true ? "Вкл" : "Выкл", vpn?.Enabled == true));
        screen.Children.Add(new TextBlock
        {
            Text = Localization.Translate("Профиль VPN"), Foreground = Foreground, FontSize = 14,
            FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 2, 0, 0),
        });
        var profiles = new StackPanel { Spacing = 5 };
        if (vpn is null || vpn.Profiles.Count == 0)
            profiles.Children.Add(Muted(vpn is null ? "Проверьте VPN в приложении" : "Профили не добавлены"));
        else foreach (var name in vpn.Profiles.Take(3))
            profiles.Children.Add(VpnPreviewRow(name, null, name == vpn.ActiveProfile));
        screen.Children.Add(new ScrollViewer
        {
            Content = profiles, Height = 137,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        });
        var navigation = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*") };
        navigation.Children.Add(VpnPreviewRow("Назад", null, false));
        var next = VpnPreviewRow("Далее", null, false);
        next.Margin = new Thickness(5, 0, 0, 0);
        Grid.SetColumn(next, 1);
        navigation.Children.Add(next);
        screen.Children.Add(navigation);
        screen.Children.Add(new TextBlock
        {
            Text = Localization.Translate(vpn is null ? "Состояние не прочитано" :
                !vpn.Installed ? "Установите компоненты VPN" :
                !vpn.Configured ? "Сеть ещё не настроена" :
                !vpn.Enabled ? "Wi-Fi с VPN выключен" :
                vpn.CoreRunning ? "Ядро VPN запущено" : "Проверьте состояние VPN"),
            Foreground = Secondary, FontSize = 10,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        previewColumn.Children.Add(new Border
        {
            Width = 240, Height = 324, Background = Canvas,
            BorderBrush = Elevated, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12), Child = screen,
        });
        previewColumn.Children.Add(Muted(vpn is null
            ? "Состояние появится после проверки VPN."
            : "Последнее прочитанное состояние модема."));
        Grid.SetColumn(previewColumn, 1);
        columns.Children.Add(previewColumn);
        panel.Children.Add(columns);
    }

    private static Border VpnPreviewRow(string title, string? detail, bool active)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        row.Children.Add(new TextBlock
        {
            Text = Localization.Translate(title), Foreground = active ? Accent : Foreground,
            FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        if (detail is not null)
        {
            var value = new TextBlock
            {
                Text = Localization.Translate(detail), Foreground = active ? Accent : Secondary,
                FontSize = 10, VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(value, 1);
            row.Children.Add(value);
        }
        return new Border
        {
            Background = Elevated, CornerRadius = new CornerRadius(8),
            Padding = new Thickness(9, 7), MinHeight = 37,
            BorderBrush = active ? Accent : Brushes.Transparent,
            BorderThickness = active ? new Thickness(1) : new Thickness(0),
            Child = row,
        };
    }

    private void BuildLauncherInfoEditor(StackPanel panel)
    {
        var heading = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        _metricCount = new TextBlock
        {
            Foreground = Accent, FontSize = 12, FontWeight = FontWeight.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        heading.Children.Add(_metricCount);
        var reset = ActionButton("По умолчанию", () =>
        {
            _form["style"] = "list";
            _form["metric_order"] = string.Join(',', DisplayMetrics.Select(metric => metric.Id));
            _form["metrics"] = string.Join(',', DisplayMetrics.Take(6).Select(metric => metric.Id));
            RenderPage();
            return Task.CompletedTask;
        }, false);
        Grid.SetColumn(reset, 1);
        heading.Children.Add(reset);
        panel.Children.Add(heading);

        var columns = new Grid { ColumnDefinitions = new ColumnDefinitions("*,260") };
        var editor = new StackPanel { Spacing = 8 };
        editor.Children.Add(Muted("Перетащите ☰ на нужную строку. Кнопки ▲ и ▼ меняют порядок с клавиатуры."));
        _metricRows = new StackPanel { Spacing = 5 };
        editor.Children.Add(new ScrollViewer
        {
            Content = _metricRows,
            MaxHeight = 465,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        });
        editor.Children.Add(Muted("Можно выбрать от 1 до 12 показателей. На модеме список и плитки прокручиваются."));
        columns.Children.Add(editor);

        var previewColumn = new StackPanel { Spacing = 9, Margin = new Thickness(18, 0, 0, 0) };
        previewColumn.Children.Add(new TextBlock
        {
            Text = Localization.Translate("ПРЕДПРОСМОТР ЭКРАНА"), Foreground = Secondary, FontSize = 10,
            FontWeight = FontWeight.SemiBold,
        });
        previewColumn.Children.Add(Muted("Тип страницы на модеме"));
        var styles = new ComboBox
        {
            ItemsSource = new[] { "Список", "Плитки" }.Select(Localization.Translate).ToArray(),
            SelectedIndex = Get("style") == "tiles" ? 1 : 0,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        styles.SelectionChanged += (_, _) =>
        {
            _form["style"] = styles.SelectedIndex == 1 ? "tiles" : "list";
            RenderLauncherPreview();
        };
        previewColumn.Children.Add(styles);
        var screen = new StackPanel { Spacing = 5, Margin = new Thickness(11) };
        screen.Children.Add(new TextBlock
        {
            Text = Localization.Translate("О модеме"), Foreground = Foreground, FontSize = 20,
            FontWeight = FontWeight.SemiBold,
        });
        screen.Children.Add(new TextBlock { Text = Localization.Translate("Данные модема"), Foreground = Secondary, FontSize = 11 });
        _previewRows = new StackPanel { Spacing = 6 };
        screen.Children.Add(new ScrollViewer
        {
            Content = _previewRows,
            Height = 242,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        });
        previewColumn.Children.Add(new Border
        {
            Width = 240, Height = 324, Background = Canvas,
            BorderBrush = Elevated, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12), Child = screen,
        });
        previewColumn.Children.Add(Muted("Значения для примера, не показания подключённого модема."));
        Grid.SetColumn(previewColumn, 1);
        columns.Children.Add(previewColumn);
        panel.Children.Add(columns);

        RenderMetricRows();
        RenderLauncherPreview();
        panel.Children.Add(Actions(("Применить настройки", ModemOperation.ApplyLauncherLayout,
            ["style", "metrics", "metric_order"])));
        panel.Children.Add(Muted("Недоступные значения на модеме показываются прочерком, устаревшие — звёздочкой."));
    }

    private string[] MetricOrder()
    {
        var ids = Get("metric_order").Split(',',
            StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return ids.Length == DisplayMetrics.Length &&
            ids.Distinct(StringComparer.Ordinal).Count() == DisplayMetrics.Length &&
            ids.ToHashSet(StringComparer.Ordinal).SetEquals(DisplayMetrics.Select(metric => metric.Id))
            ? ids : DisplayMetrics.Select(metric => metric.Id).ToArray();
    }

    private HashSet<string> EnabledMetrics() => Get("metrics")
        .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
        .Where(id => DisplayMetrics.Any(metric => metric.Id == id))
        .ToHashSet(StringComparer.Ordinal);

    private void SaveMetricSelection(IReadOnlyList<string> order, HashSet<string> enabled)
    {
        _form["metric_order"] = string.Join(',', order);
        _form["metrics"] = string.Join(',', order.Where(enabled.Contains));
    }

    private void SetMetricEnabled(string id, bool selected)
    {
        var order = MetricOrder();
        var enabled = EnabledMetrics();
        if (!selected && enabled.Count == 1 && enabled.Contains(id))
        {
            SetStatus("На странице должен остаться хотя бы один показатель.", true);
            RenderMetricRows();
            return;
        }
        if (selected) enabled.Add(id); else enabled.Remove(id);
        SaveMetricSelection(order, enabled);
        RenderMetricRows();
        RenderLauncherPreview();
    }

    private void MoveMetric(string source, string target, bool after)
    {
        if (source == target || _busy) return;
        var order = MetricOrder().ToList();
        if (!order.Remove(source)) return;
        var targetIndex = order.IndexOf(target);
        if (targetIndex < 0) return;
        order.Insert(targetIndex + (after ? 1 : 0), source);
        SaveMetricSelection(order, EnabledMetrics());
        RenderMetricRows();
        RenderLauncherPreview();
    }

    private void MoveMetricBy(string id, int delta)
    {
        if (_busy) return;
        var order = MetricOrder().ToList();
        var index = order.IndexOf(id);
        var destination = index + delta;
        if (index < 0 || destination < 0 || destination >= order.Count) return;
        (order[index], order[destination]) = (order[destination], order[index]);
        SaveMetricSelection(order, EnabledMetrics());
        RenderMetricRows();
        RenderLauncherPreview();
    }

    private void RenderMetricRows()
    {
        if (_metricRows is null) return;
        _metricRows.Children.Clear();
        var order = MetricOrder();
        var enabled = EnabledMetrics();
        if (_metricCount is not null)
            _metricCount.Text = Localization.Translate($"ПОКАЗАТЕЛИ  ·  {enabled.Count} из {DisplayMetrics.Length}");
        for (var index = 0; index < order.Length; index++)
        {
            var id = order[index];
            var metric = DisplayMetrics.Single(item => item.Id == id);
            var selected = enabled.Contains(id);
            var row = new Border
            {
                Background = selected ? Elevated : Canvas,
                BorderBrush = Surface,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(8, 6),
            };
            var content = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto") };
            var label = new StackPanel { Spacing = 2 };
            label.Children.Add(new TextBlock
            {
                Text = Localization.Translate(metric.Title), Foreground = selected ? Foreground : Secondary,
                FontSize = 12, FontWeight = FontWeight.Medium,
                TextWrapping = TextWrapping.Wrap,
            });
            label.Children.Add(new TextBlock
            {
                Text = Localization.Translate(metric.Detail), Foreground = Secondary, FontSize = 10,
                TextWrapping = TextWrapping.Wrap,
            });
            var box = new CheckBox
            {
                Content = label, IsChecked = selected, Foreground = Foreground,
                VerticalAlignment = VerticalAlignment.Center,
                IsEnabled = !_busy,
            };
            box.IsCheckedChanged += (_, _) => SetMetricEnabled(id, box.IsChecked == true);
            content.Children.Add(box);
            var arrows = new StackPanel { Spacing = 1, Margin = new Thickness(6, 0) };
            foreach (var delta in new[] { -1, 1 })
            {
                var step = delta;
                var arrow = new Button
                {
                    Content = delta < 0 ? "▲" : "▼", Background = Brushes.Transparent,
                    Foreground = Secondary, BorderThickness = new Thickness(0),
                    Padding = new Thickness(4, 0), FontSize = 10,
                    IsEnabled = !_busy && index + delta >= 0 && index + delta < order.Length,
                };
                ToolTip.SetTip(arrow, Localization.Translate(delta < 0 ? "Переместить выше" : "Переместить ниже"));
                arrow.Click += (_, _) => MoveMetricBy(id, step);
                arrows.Children.Add(arrow);
            }
            Grid.SetColumn(arrows, 1);
            content.Children.Add(arrows);
            var handle = new TextBlock
            {
                Text = "☰", Foreground = Accent, FontSize = 19,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(6, 0, 2, 0),
            };
            ToolTip.SetTip(handle, Localization.Translate("Перетащить для изменения порядка"));
            handle.PointerPressed += async (_, e) =>
            {
                if (_busy || !e.GetCurrentPoint(handle).Properties.IsLeftButtonPressed) return;
                var data = new DataTransfer();
                data.Add(DataTransferItem.Create(MetricDragFormat, id));
                await DragDrop.DoDragDropAsync(e, data, DragDropEffects.Move);
            };
            Grid.SetColumn(handle, 2);
            content.Children.Add(handle);
            row.Child = content;
            DragDrop.SetAllowDrop(row, true);
            DragDrop.AddDragOverHandler(row, (_, e) =>
            {
                e.DragEffects = e.DataTransfer.TryGetValue(MetricDragFormat) is string source &&
                    DisplayMetrics.Any(item => item.Id == source)
                    ? DragDropEffects.Move : DragDropEffects.None;
                row.BorderBrush = e.DragEffects == DragDropEffects.Move ? Accent : Surface;
                e.Handled = true;
            });
            DragDrop.AddDragLeaveHandler(row, (_, _) => row.BorderBrush = Surface);
            DragDrop.AddDropHandler(row, (_, e) =>
            {
                row.BorderBrush = Surface;
                if (e.DataTransfer.TryGetValue(MetricDragFormat) is string source)
                    MoveMetric(source, id, e.GetPosition(row).Y >= row.Bounds.Height / 2);
                e.Handled = true;
            });
            _metricRows.Children.Add(row);
        }
    }

    private void RenderLauncherPreview()
    {
        if (_previewRows is null) return;
        _previewRows.Children.Clear();
        var selected = MetricOrder().Where(EnabledMetrics().Contains)
            .Select(id => DisplayMetrics.Single(metric => metric.Id == id)).ToArray();
        if (Get("style") == "tiles")
        {
            for (var index = 0; index < selected.Length; index += 2)
            {
                var pair = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*"), Margin = new Thickness(0, 0, 0, 2) };
                pair.Children.Add(PreviewMetricCard(selected[index], true));
                if (index + 1 < selected.Length)
                {
                    var second = PreviewMetricCard(selected[index + 1], true);
                    second.Margin = new Thickness(5, 0, 0, 0);
                    Grid.SetColumn(second, 1);
                    pair.Children.Add(second);
                }
                _previewRows.Children.Add(pair);
            }
        }
        else foreach (var metric in selected)
            _previewRows.Children.Add(PreviewMetricCard(metric, false));
    }

    private static Border PreviewMetricCard(DisplayMetric metric, bool tile)
    {
        var content = new StackPanel { Spacing = tile ? 7 : 2 };
        content.Children.Add(new TextBlock
        {
            Text = Localization.Translate(tile ? metric.TileTitle : metric.Title),
            Foreground = Secondary, FontSize = tile ? 11 : 10,
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(new TextBlock
        {
            Text = Localization.Translate(metric.Example), Foreground = Foreground,
            FontSize = tile ? 14 : 15, FontWeight = FontWeight.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        return new Border
        {
            Background = Elevated, CornerRadius = new CornerRadius(8),
            Padding = new Thickness(tile ? 8 : 9, 7),
            MinHeight = tile ? 78 : 48, Child = content,
        };
    }

    private void BuildImei()
    {
        if (_sections[2] == 0)
        {
            AddCard("Текущий IMEI", "Перед изменением сохраните резервную копию.", panel =>
            {
                panel.Children.Add(ValueLine("IMEI", _snapshot?.Imei));
                panel.Children.Add(Actions(
                    ("Прочитать IMEI", ModemOperation.ReadImei, null),
                    ("Создать бэкап IMEI", ModemOperation.CreateImeiBackup, null)));
                panel.Children.Add(ActionButton("Продолжить незавершённую операцию", async () =>
                    await ExecuteAsync(ModemOperation.ResumeImei, (string[]?)null), false));
                panel.Children.Add(Muted("Используйте эту кнопку после прерванной записи или перезагрузки. Повторная запись проверяет журнал, NV и config."));
            });
            AddCard("Новые IMEI", "Оба номера должны иметь 15 цифр и верную контрольную цифру. Перед записью создаётся проверенный бэкап.", panel =>
            {
                panel.Children.Add(Field("IMEI 1", "imei1", "15 цифр"));
                panel.Children.Add(Field("IMEI 2", "imei2", "15 цифр"));
                panel.Children.Add(ActionButton("Получить второй из первого", async () =>
                {
                    try
                    {
                        _form["imei2"] = ImeiCodec.Second(Get("imei1"));
                        RenderPage();
                        SetStatus("Второй IMEI рассчитан из первого.");
                    }
                    catch (Exception error) { SetStatus(error.Message, true); }
                }, false));
                panel.Children.Add(ActionButton("Проверить IMEI", async () =>
                {
                    var first = Get("imei1");
                    var second = Get("imei2");
                    SetStatus(ImeiCodec.IsValid(first) && ImeiCodec.IsValid(second) && first != second
                        ? "Оба IMEI прошли проверку формата и контрольной цифры."
                        : "Проверьте оба IMEI: 15 цифр, верная контрольная цифра, номера различаются.",
                        !(ImeiCodec.IsValid(first) && ImeiCodec.IsValid(second) && first != second));
                    await Task.CompletedTask;
                }, false));
                var writeImei = new WrapPanel { Orientation = Orientation.Horizontal };
                writeImei.Children.Add(ActionButton("Записать оба IMEI", async () =>
                {
                    var first = Get("imei1");
                    var second = Get("imei2");
                    if (!ImeiCodec.IsValid(first) || !ImeiCodec.IsValid(second) || first == second)
                    {
                        SetStatus("Оба IMEI должны быть действительными и различаться.", true);
                        return;
                    }
                    if (await ConfirmAsync("Записать оба IMEI?", $"IMEI 1: {first}\nIMEI 2: {second}\nВо время записи модем может перезагрузиться."))
                        await ExecuteAsync(ModemOperation.ApplyImei, ["imei1", "imei2"]);
                }, true));
                writeImei.Children.Add(OperationInfoButton(OperationHelpContent.Imei));
                panel.Children.Add(writeImei);
            });
        }
        else
        {
            AddBackups("IMEI", restoreOperation: ModemOperation.RestoreImeiBackup);
        }
    }

    private void BuildTtl()
    {
        AddCard("Параметры TTL", "Настройки применяются к трафику модема.", panel =>
        {
            panel.Children.Add(ValueLine("Текущее состояние", _snapshot?.Ttl));
            panel.Children.Add(Field("Исходящий TTL", "outbound_ttl", "64"));
            panel.Children.Add(Field("Прибавка к входящему TTL", "incoming_delta", "1"));
            panel.Children.Add(Actions(
                ("Проверить TTL", ModemOperation.RefreshTtl, null),
                ("Применить", ModemOperation.ApplyTtl, ["outbound_ttl", "incoming_delta"])));
        });
    }

    private void BuildVpn()
    {
        AddCard("VPN на модеме", "Проверка и установка компонентов VPN.", panel =>
        {
            panel.Children.Add(ValueLine("Состояние", _snapshot?.Vpn));
            panel.Children.Add(Actions(
                ("Проверить VPN", ModemOperation.RefreshVpn, null),
                ("Установить / обновить", ModemOperation.InstallVpn, null)));
        });
    }

    private void BuildApplications()
    {
        if (_sections[5] == 2)
        {
            AddCard("Установка пакетов через opkg", "Для установки приложений через терминал сначала установите opkg. Сам терминал открывается автоматически при подключении по SSH.", panel =>
            {
                panel.Children.Add(Muted("OpenWrt 23.05.4 · aarch64_cortex-a53 · /data"));
                var opkg = _applications.FirstOrDefault(app => app.Id == "opkg");
                panel.Children.Add(Muted(opkg?.StatusKnown == true ? opkg.Installed ? "opkg установлен" : "opkg не установлен" : "Состояние opkg пока не проверено"));
                if (_terminal?.IsConnected == true)
                    panel.Children.Add(ActionButton("Отключить терминал для управления opkg", async () => { _terminalAutoAttempted = true; await CloseTerminalAsync(); }, false));
                else
                {
                    panel.Children.Add(Actions(("Проверить opkg", ModemOperation.RefreshOpkg, null)));
                    if (opkg?.Installed != true && VerifiedCatalogStore.Shared.Allows("opkg"))
                        panel.Children.Add(Actions(("Установить opkg", ModemOperation.InstallOpkg, null)));
                }
            });
            AddTerminalCard();
            AddCard("Инструкция opkg", "Платформа проверенной прошивки B31: OpenWrt 23.05.4, aarch64_cortex-a53. Сначала установите адаптер, прочитайте источники и выполните opkg update. Затем можно выполнить opkg list, opkg install <пакет> или opkg remove <пакет>.", panel =>
            {
                panel.Children.Add(Muted("opkg update\nopkg list\nopkg install <package>\nopkg remove <package>"));
                if (_terminal?.IsConnected != true)
                    panel.Children.Add(Actions(("Удалить адаптер", ModemOperation.RemoveOpkg, null)));
            });
            AddCard("Источники пакетов opkg", "Редактор приватного адаптера. Одна запись src/gz на строку.", panel =>
            {
                panel.Children.Add(ActionButton("Прочитать с модема", async () => await ExecuteAsync(ModemOperation.LoadOpkgFeeds, (string[]?)null), false));
                panel.Children.Add(Field("Источники", "feeds", "src/gz имя https://адрес/каталога", multiline: true));
                panel.Children.Add(ActionButton("Сохранить источники", async () => await ExecuteAsync(ModemOperation.SaveOpkgFeeds, ["feeds"]), true));
            });
            return;
        }
        AddCard(_sections[5] == 0 ? "Установленные приложения" : "Каталог приложений",
            "Каждое приложение показывает текущий статус на модеме и доступное действие.", panel =>
        {
            var catalog = VerifiedCatalogStore.Shared;
            panel.Children.Add(Actions(("Обновить список", ModemOperation.RefreshApplications, null),
                ("Проверить утилиты", ModemOperation.RefreshDiagnostics, null)));
            if (_sections[5] == 1)
            {
                panel.Children.Add(Muted("В каталоге только приложения, проверенные на модеме. Список обновляется отдельно от программы через GitHub."));
                panel.Children.Add(Muted(catalog.StatusText(Localization.Language)));
                if (!string.IsNullOrWhiteSpace(catalog.Error)) panel.Children.Add(Muted(catalog.ErrorText(Localization.Language)));
                var update = ActionButton("Обновить каталог с GitHub", async () => { await catalog.UpdateAsync(); RenderPage(); }, false);
                update.IsEnabled = !catalog.IsUpdating;
                panel.Children.Add(update);
            }
            var apps = _applications.Where(app => _sections[5] == 0
                ? app.Installed
                : VerifiedCatalogStore.Shared.Allows(app.Id)).ToList();
            if (_sections[5] == 1)
                apps = catalog.Entries.Select(entry => _applications.FirstOrDefault(app => app.Id == entry.Id)
                    ?? new ModemAppInfo(entry.Id, entry.Name, entry.Version, false, entry.Description.Text(Localization.Language), false)).ToList();
            if (apps.Count == 0)
            {
                panel.Children.Add(Muted(_sections[5] == 1 ? "В проверенном каталоге пока нет приложений для этой версии программы." : "Список пока пуст. Подключитесь и нажмите «Обновить список»."));
                return;
            }
            foreach (var app in apps)
            {
                var isStock = app.Id.StartsWith("stock:", StringComparison.OrdinalIgnoreCase);
                var isSsclash = app.Id.Contains("ssclash", StringComparison.OrdinalIgnoreCase) ||
                    app.Name.Contains("SSClash", StringComparison.OrdinalIgnoreCase);
                var row = new StackPanel { Spacing = 7 };
                var applicationLayout = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 18 };
                applicationLayout.Children.Add(row);
                var verifiedEntry = VerifiedCatalogStore.Shared.Entry(app.Id);
                var displayVersion = _sections[5] == 1 ? verifiedEntry?.Version ?? app.Version : app.Version;
                row.Children.Add(new TextBlock { Text = app.Name + (displayVersion is null ? "" : $" · {displayVersion}"), Foreground = Foreground, FontWeight = FontWeight.SemiBold });
                row.Children.Add(Muted(verifiedEntry?.Description.Text(Localization.Language) ?? app.Description ?? app.Id));
                if (_sections[5] == 1 && verifiedEntry is not null)
                    row.Children.Add(Muted(verifiedEntry.Verification.Summary.Text(Localization.Language)));
                if (isStock) row.Children.Add(Muted("Штатное приложение модема"));
                else row.Children.Add(Muted(app.StatusKnown
                    ? app.Installed ? "● Установлено" : "○ Не установлено"
                    : "○ Состояние не проверено"));
                if (isSsclash && !app.Installed)
                {
                    row.Children.Add(Field("Пароль SSClash-Go", "ssclash_password", "От 8 до 128 символов", secret: true));
                    row.Children.Add(Field("Повторите пароль", "ssclash_confirmation", "Повторите пароль", secret: true));
                }
                if (!isStock && app.StatusKnown)
                {
                var appAction = ActionButton(app.Installed ? "Удалить" : "Установить", async () =>
                {
                    if (app.Installed && !await ConfirmAsync("Удалить приложение?", app.Name)) return;
                    if (isSsclash && !app.Installed)
                    {
                        var password = Get("ssclash_password");
                        if (password.Length is < 8 or > 128 || password.Any(c => c is < '!' or > '~') ||
                            password != Get("ssclash_confirmation"))
                        {
                            SetStatus("Пароль SSClash-Go: 8–128 печатных ASCII символов, подтверждение должно совпасть.", true);
                            return;
                        }
                    }
                    var parameters = new Dictionary<string, string> { ["id"] = app.Id };
                    if (isSsclash && !app.Installed) parameters["ssclash_password"] = Get("ssclash_password");
                    await ExecuteAsync(app.Installed ? ModemOperation.RemoveApplication : ModemOperation.InstallApplication,
                        parameters);
                    await RefreshApplicationsAsync();
                }, !app.Installed);
                Grid.SetColumn(appAction, 1);
                appAction.VerticalAlignment = VerticalAlignment.Center;
                appAction.Margin = new Thickness(0);
                applicationLayout.Children.Add(appAction);
                }
                panel.Children.Add(new Border
                {
                    Child = applicationLayout,
                    Background = Elevated,
                    CornerRadius = new CornerRadius(9),
                    Padding = new Thickness(13),
                    Margin = new Thickness(0, 2, 0, 2),
                });
            }
        });
    }

    private void BuildAdministration()
    {
        switch (_sections[6])
        {
            case 0:
                AddCard("Доступы", "Управление SSH пользователями и службами доступа.", panel =>
                {
                    panel.Children.Add(Field("Новый пользователь", "account_username", "Имя пользователя"));
                    panel.Children.Add(Field("Пароль", "account_password", "Пароль", secret: true));
                    panel.Children.Add(ActionButton("Создать пользователя", async () =>
                        await ExecuteAsync(ModemOperation.CreateSshAccount, new Dictionary<string, string>
                        {
                            ["username"] = Get("account_username"), ["password"] = Get("account_password"),
                        }), true));
                    panel.Children.Add(Field("Удалить пользователя", "remove_username", "Имя пользователя"));
                    panel.Children.Add(ActionButton("Удалить пользователя", async () =>
                    {
                        if (await ConfirmAsync("Удалить SSH пользователя?", Get("remove_username")))
                            await ExecuteAsync(ModemOperation.RemoveSshAccount, new Dictionary<string, string> { ["username"] = Get("remove_username") });
                    }, false));
                    panel.Children.Add(Field("Служба", "service", "dashboard / agent / userSSH"));
                    panel.Children.Add(Field("Действие", "service_action", "start / stop / restart"));
                    panel.Children.Add(Actions(("Изменить службу", ModemOperation.ChangeAccessService, ["service", "service_action"])));
                    panel.Children.Add(ActionButton("Перезагрузить модем", async () =>
                    {
                        if (await ConfirmAsync("Перезагрузить модем?", "Соединение будет временно потеряно."))
                            await ExecuteAsync(ModemOperation.RebootDevice, (string[]?)null);
                    }, false));
                });
                break;
            case 1:
                AddCard("Бэкап данных модема", "Сохраняет NV, persist, /data и конфигурацию. Создаётся с работающего модема; автоматического восстановления нет.", panel =>
                    panel.Children.Add(Actions(("Создать бэкап данных", ModemOperation.CreateDeviceBackup, null))));
                AddBackups("Устройство", restoreOperation: null);
                AddCard("Полный образ eMMC", "Считывает пользовательскую область eMMC и boot0/boot1 по SSH. Нужны свободное место на ПК и время; снимок работающего модема не атомарен. RPMB/OTP и автоматическое восстановление не поддерживаются. Доступно только на проверенной B31.", panel =>
                    panel.Children.Add(ActionButton("Создать полный образ", async () =>
                    {
                        if (await ConfirmAsync("Создать полный образ eMMC?", "Образ может занимать несколько гигабайт. Во время чтения модем должен оставаться подключённым к питанию и ПК."))
                            await ExecuteAsync(ModemOperation.CreateSystemBackup, (string[]?)null);
                    }, true)));
                AddBackups("Система", restoreOperation: null);
                break;
            case 2:
                AddCard("Журнал действий", "События последней работы с модемом.", panel =>
                {
                    panel.Children.Add(ActionButton("Обновить журнал", async () => await RefreshLogsAsync(), false));
                    foreach (var entry in _logs.OrderByDescending(x => x.Timestamp).Take(100))
                        panel.Children.Add(Muted($"{entry.Timestamp.LocalDateTime:dd.MM HH:mm:ss}  {entry.Level}  {entry.Message}"));
                    if (_logs.Count == 0) panel.Children.Add(Muted("Записей пока нет."));
                });
                break;
        }
    }

    private void BuildModem()
    {
        switch (_sections[7])
        {
            case 0:
                AddSnapshotCard();
                break;
            case 1:
                AddCard("Память модема", "Значения считываются с подключённого устройства.", panel =>
                {
                    panel.Children.Add(ValueLine("Память", _snapshot?.Storage));
                    panel.Children.Add(Actions(("Обновить", ModemOperation.RefreshDevice, null)));
                });
                break;
        }
    }

    private void AddSnapshotCard()
    {
        AddCard("Состояние устройства", "Сведения загружаются по кнопке «Обновить». Проверки компонентов выполняются в их разделах.", panel =>
        {
            panel.Children.Add(ValueLine("Подключение", _snapshot?.Status));
            panel.Children.Add(ValueLine("Модель", _snapshot?.Model));
            panel.Children.Add(ValueLine("Прошивка", _snapshot?.Firmware));
            panel.Children.Add(ValueLine("Серийный номер", _snapshot?.Serial));
            panel.Children.Add(ValueLine("IP адрес", _snapshot?.IpAddress));
            panel.Children.Add(ValueLine("Канал", _snapshot?.ConnectionMode));
            panel.Children.Add(ValueLine("Батарея", _snapshot?.Battery));
            if (_snapshot?.Details is { } details)
                foreach (var detail in details)
                    panel.Children.Add(ValueLine(detail.Key, detail.Value));
        });
    }

    private void AddBackups(string category, ModemOperation? restoreOperation)
    {
        AddCard($"Бэкапы · {category}", restoreOperation is null
            ? "Сохранённые копии можно повторно проверить по SHA-256."
            : "Выберите сохранённую копию для проверки или восстановления.", panel =>
        {
            panel.Children.Add(ActionButton("Обновить список", async () => await RefreshBackupsAsync(), false));
            var backups = _backups.Where(b => b.Category.Contains(category, StringComparison.OrdinalIgnoreCase)).ToList();
            if (backups.Count == 0)
            {
                panel.Children.Add(Muted("Список бэкапов пуст."));
                return;
            }
            foreach (var backup in backups.OrderByDescending(b => b.CreatedAt))
            {
                var row = new StackPanel { Spacing = 5, Margin = new Thickness(0, 8, 0, 8) };
                row.Children.Add(new TextBlock { Text = backup.Name, Foreground = Foreground, FontWeight = FontWeight.SemiBold });
                row.Children.Add(Muted($"{backup.CreatedAt.LocalDateTime:dd.MM.yyyy HH:mm} · {backup.Path ?? backup.Id}"));
                if (category == "Устройство")
                    row.Children.Add(ActionButton("Проверить целостность", async () =>
                        await ExecuteAsync(ModemOperation.VerifyDeviceBackup, new Dictionary<string, string> { ["id"] = backup.Id }), false));
                if (category == "Система")
                    row.Children.Add(ActionButton("Проверить SHA-256 образа", async () =>
                        await ExecuteAsync(ModemOperation.VerifySystemBackup, new Dictionary<string, string> { ["id"] = backup.Id }), false));
                if (restoreOperation is { } restore)
                    row.Children.Add(ActionButton("Восстановить", async () =>
                    {
                        if (await ConfirmAsync("Восстановить бэкап?", backup.Name))
                            await ExecuteAsync(restore, new Dictionary<string, string> { ["id"] = backup.Id });
                    }, false));
                panel.Children.Add(row);
            }
        });
    }

    private void AddTerminalCard()
    {
        AddCard("Интерактивный терминал", "Полный shell модема: команды, скрипты и интерактивные программы. Ввод отправляется по Enter.", panel =>
        {
            var buttons = new WrapPanel();
            buttons.Children.Add(ActionButton(_terminal?.IsConnected == true ? "Переподключить" : "Подключить Terminal", async () => { await CloseTerminalAsync(); await OpenTerminalAsync(); }, true));
            buttons.Children.Add(ActionButton("Ctrl+C", async () =>
            {
                if (_terminal?.IsConnected == true) await _terminal.SendAsync("\u0003", _lifetime.Token);
            }, false));
            buttons.Children.Add(ActionButton("Отключить", async () => { _terminalAutoAttempted = true; await CloseTerminalAsync(); }, false));
            panel.Children.Add(buttons);
            _terminalOutput = new SelectableTextBlock
            {
                Text = _terminalText,
                Name = "TerminalOutput",
                TextWrapping = TextWrapping.NoWrap,
                FontFamily = new FontFamily("Consolas, Cascadia Mono, monospace"),
                Background = Canvas,
                Foreground = Foreground,
            };
            _terminalViewport = new ScrollViewer
            {
                Name = "TerminalViewport", Content = _terminalOutput, Height = 320, AllowAutoHide = false,
                HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
                Background = Canvas,
            };
            _terminalViewport.ScrollChanged += (_, args) =>
            {
                if (args.ViewportDelta != default && _terminalFollowOutput) FollowTerminalOutput();
                if (args.ExtentDelta == default && args.ViewportDelta == default)
                    _terminalFollowOutput = _terminalViewport.Offset.Y >= Math.Max(0, _terminalViewport.Extent.Height - _terminalViewport.Viewport.Height) - 1;
            };
            panel.Children.Add(_terminalViewport);
            FollowTerminalOutput();
            if (_snapshot?.IsConnected != true || _snapshot.ConnectionMode != "SSH") panel.Children.Add(Muted("Для терминала подключитесь к модему по SSH."));
            _terminalInput = new TextBox { Name = "TerminalInput", Watermark = Localization.Translate("Команда"), Background = Elevated, Foreground = Foreground };
            _terminalInput.KeyDown += async (_, args) =>
            {
                if (args.Key == Avalonia.Input.Key.Enter)
                {
                    args.Handled = true;
                    await SendTerminalAsync();
                }
            };
            panel.Children.Add(_terminalInput);
            panel.Children.Add(ActionButton("Отправить", SendTerminalAsync, true));
        });
    }

    private async Task OpenTerminalAsync()
    {
        if (_terminalOpening || _terminal?.IsConnected == true) return;
        if (_snapshot?.IsConnected != true || _snapshot.ConnectionMode != "SSH")
        {
            SetStatus("Для терминала подключитесь к модему по SSH.", true);
            return;
        }
        _terminalOpening = true;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _terminalOpenCancellation = cancellation;
        try
        {
            await CloseTerminalAsync(cancelOpening: false);
            var terminal = await _service.OpenTerminalAsync(cancellation.Token);
            if (cancellation.IsCancellationRequested)
            {
                await terminal.DisposeAsync();
                cancellation.Token.ThrowIfCancellationRequested();
            }
            _terminal = terminal;
            _terminal.OutputReceived += TerminalOutputReceived;
            SetStatus("Терминал подключён.");
            if (_page == 5 && _sections[5] == 2) RenderPage();
            _terminalInput?.Focus();
        }
        catch (OperationCanceledException) { SetStatus("Подключение терминала отменено."); }
        catch (Exception error) { SetStatus(error.Message, true); }
        finally { _terminalOpening = false; _terminalOpenCancellation = null; }
    }

    private void TerminalOutputReceived(object? sender, TerminalDataEventArgs args) =>
        Dispatcher.UIThread.Post(() =>
        {
            _terminalText += args.Text;
            if (_terminalText.Length > 100_000) _terminalText = _terminalText[^100_000..];
            if (_terminalOutput is not null)
            {
                _terminalOutput.Text = _terminalText;
                FollowTerminalOutput();
            }
        });

    private void FollowTerminalOutput()
    {
        if (!_terminalFollowOutput || _terminalViewport is not { } viewport) return;
        // Text layout must establish the new extent before choosing the final
        // offset; caret movement in a bounded TextBox happened before layout.
        Dispatcher.UIThread.Post(() =>
        {
            if (_terminalFollowOutput && ReferenceEquals(viewport, _terminalViewport))
            {
                viewport.UpdateLayout();
                viewport.ScrollToEnd();
            }
        }, DispatcherPriority.Loaded);
    }

    private async Task SendTerminalAsync()
    {
        if (_terminal?.IsConnected != true)
        {
            SetStatus("Сначала откройте терминал.", true);
            return;
        }
        var command = _terminalInput?.Text;
        if (string.IsNullOrWhiteSpace(command)) return;
        try
        {
            await _terminal.SendAsync(command + "\r", _lifetime.Token);
            if (_terminalInput is not null) _terminalInput.Text = "";
        }
        catch (Exception error) { SetStatus(error.Message, true); }
    }

    private async Task CloseTerminalAsync(bool cancelOpening = true)
    {
        if (cancelOpening) _terminalOpenCancellation?.Cancel();
        if (_terminal is null) return;
        _terminal.OutputReceived -= TerminalOutputReceived;
        await _terminal.DisposeAsync();
        _terminal = null;
        SetStatus("Терминал отключён.");
        if (!_lifetime.IsCancellationRequested && _page == 5 && _sections[5] == 2) RenderPage();
    }

    private void AddCard(string title, string description, Action<StackPanel> build)
    {
        var panel = new StackPanel { Spacing = 13 };
        panel.Children.Add(new TextBlock { Text = Localization.Translate(title), Foreground = Foreground, FontSize = 18, FontWeight = FontWeight.SemiBold });
        panel.Children.Add(Muted(description));
        build(panel);
        _body.Children.Add(new Border
        {
            Background = Surface,
            CornerRadius = new CornerRadius(14),
            BorderBrush = Elevated, BorderThickness = new Thickness(1),
            Padding = new Thickness(20),
            Child = panel,
        });
    }

    private static TextBlock Muted(string value) => new()
    {
        Text = Localization.Translate(value),
        Foreground = Secondary,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
    };

    private static Control ValueLine(string label, string? value)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("170,*") };
        row.Children.Add(new TextBlock { Text = Localization.Translate(label), Foreground = Secondary, FontSize = 12 });
        var data = new TextBlock { Text = string.IsNullOrWhiteSpace(value) ? "—" : Localization.Translate(value), Foreground = Foreground, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(data, 1);
        row.Children.Add(data);
        return row;
    }

    private Control Field(string label, string key, string watermark, bool secret = false, bool multiline = false)
    {
        var stack = new StackPanel { Spacing = 5 };
        stack.Children.Add(new TextBlock { Text = Localization.Translate(label), Foreground = Secondary, FontSize = 12 });
        var input = new TextBox
        {
            Text = secret ? _preparationSecrets.GetValueOrDefault(key, "") : Get(key),
            Watermark = Localization.Translate(watermark),
            Background = Elevated,
            Foreground = Foreground,
            MaxWidth = 600,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MinWidth = 220,
            MinHeight = 36, Padding = new Thickness(10, 7),
        };
        if (secret) input.PasswordChar = '●';
        if (multiline)
        {
            input.AcceptsReturn = true;
            input.MinHeight = 140;
            input.MaxWidth = 700;
        }
        if (secret)
        {
            _secretFields[key] = input;
            var previousText = input.Text ?? "";
            if (IsPreparationSecret(key)) input.TextChanged += (_, _) =>
            {
                if (!_secretFields.TryGetValue(key, out var current) || !ReferenceEquals(current, input)) return;
                var value = input.Text ?? "";
                if (value == previousText) return;
                previousText = value;
                if (value.Length == 0) _preparationSecrets.Remove(key); else _preparationSecrets[key] = value;
                if (key is "web_password" or "backup_key_suffix") InvalidateBackupKeyCheck();
                UpdateDiagnosticAvailability();
            };
        }
        else input.TextChanged += (_, _) =>
        {
            var changed = Get(key) != (input.Text ?? "");
            _form[key] = input.Text ?? "";
            if (key is "host" or "key_path" or "known_hosts_path")
            {
                if (changed) ClearSecrets();
                UpdateDiagnosticConnectionStatus();
            }
            if (key == "host") { if(changed) InvalidateBackupKeyCheck(); UpdateDiagnosticAvailability(); }
        };
        stack.Children.Add(input);
        return stack;
    }

    private Control FileField(string label, string key, string watermark)
    {
        var stack = new StackPanel { Spacing = 5 };
        stack.Children.Add(Muted(label));
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 8 };
        var input = new TextBox
        {
            Text = Get(key), Watermark = Localization.Translate(watermark), Background = Elevated, Foreground = Foreground,
            MinWidth = 220, MinHeight = 36, Padding = new Thickness(10, 7), HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        input.TextChanged += (_, _) =>
        {
            var changed = Get(key) != (input.Text ?? "");
            _form[key] = input.Text ?? "";
            if (key is "key_path" or "known_hosts_path")
            {
                if (changed) ClearSecrets();
                UpdateDiagnosticConnectionStatus();
            }
        };
        row.Children.Add(input);
        var browse = ActionButton("▱", async () =>
        {
            var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = label, AllowMultiple = false,
            });
            if (files.Count == 1 && files[0].Path.IsFile)
                input.Text = files[0].Path.LocalPath;
        }, false);
        browse.Name = key + "_browse";
        browse.FontSize = 20;
        ToolTip.SetTip(browse, Localization.Translate("Выбрать файл") + ": " + Localization.Translate(label));
        Avalonia.Automation.AutomationProperties.SetName(browse, Localization.Translate("Выбрать файл") + ": " + Localization.Translate(label));
        browse.Margin = new Thickness(0);
        Grid.SetColumn(browse, 1);
        row.Children.Add(browse);
        stack.Children.Add(row);
        return stack;
    }

    private string Get(string key) => _secretFields.TryGetValue(key, out var secret)
        ? secret.Text ?? ""
        : IsPreparationSecret(key) ? _preparationSecrets.GetValueOrDefault(key, "") : _form.GetValueOrDefault(key, "").Trim();

    private WrapPanel Actions(params (string Label, ModemOperation Operation, string[]? Parameters)[] actions)
    {
        var panel = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var (label, operation, parameters) in actions)
            panel.Children.Add(ActionButton(label, async () => await ExecuteAsync(operation, parameters), operation is ModemOperation.Connect or ModemOperation.InstallAgent or ModemOperation.InstallLauncher));
        return panel;
    }

    private Button OperationInfoButton(OperationHelpTopic topic)
    {
        var button = new Button
        {
            Content = "ⓘ",
            Background = Brushes.Transparent,
            Foreground = Accent,
            BorderThickness = new Thickness(1),
            BorderBrush = Elevated,
            Padding = new Thickness(7, 3),
            Margin = new Thickness(0, 0, 8, 7),
            FontSize = 18,
            MinWidth = 37,
            MinHeight = 35,
        };
        ToolTip.SetTip(button, Localization.Translate(topic.AccessibleName));
        button.Click += async (_, _) => await ShowOperationHelpAsync(topic);
        return button;
    }

    private async Task ShowAboutAsync()
    {
        var dialog = new Window { Title = Localization.Translate("О программе"), Width = 580, Height = 395,
            CanResize = false, Background = Surface, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var panel = new StackPanel { Margin = new Thickness(28), Spacing = 15 };
        panel.Children.Add(new TextBlock { Text = "ZTE U60Pro Manager", Foreground = Foreground, FontSize = 25, FontWeight = FontWeight.Bold });
        panel.Children.Add(Muted("Windows x64 · " + typeof(MainWindow).Assembly.GetName().Version?.ToString(3)));
        var attribution = new WrapPanel { Orientation = Orientation.Horizontal };
        Button LinkButton(string title, string url)
        {
            var button = new Button { Content = new TextBlock { Text = title, TextDecorations = TextDecorations.Underline, Foreground = Accent, FontSize = 13 },
                Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0), MinHeight = 0, MinWidth = 0, Tag = url };
            button.Click += (_, _) => { try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch (Exception error) { SetStatus(error.Message, true); } };
            return button;
        }
        var sentence = Localization.IsEnglish
            ? "Developed with support from the uFactor expert division of UserGate."
            : "Приложение разработано при поддержке экспертного подразделения uFactor компании UserGate.";
        foreach (var word in sentence.Split(' '))
        {
            var brandWord = word.TrimEnd('.');
            if (brandWord is "uFactor" or "UserGate")
            {
                var link = LinkButton(word, brandWord == "uFactor" ? "https://usergate.com/ufactor" : "https://usergate.com");
                link.Height = 23;
                link.VerticalContentAlignment = VerticalAlignment.Center;
                link.Margin = new Thickness(0, 0, 3, 0);
                attribution.Children.Add(link);
            }
            else
                attribution.Children.Add(new Border { Height = 23, Margin = new Thickness(0, 0, word == "." ? 0 : 3, 0), Child = new TextBlock
                { Text = word, Foreground = Secondary, FontSize = 13, VerticalAlignment = VerticalAlignment.Center } });
        }
        panel.Children.Add(attribution);
        var github = LinkButton("GitHub ↗", "https://github.com/SadykovIV/ZTE_U60Pro");
        github.HorizontalAlignment = HorizontalAlignment.Left;
        panel.Children.Add(github);
        panel.Children.Add(Muted("Настройки подключения и резервные копии сохраняются в существующем профиле ZTE IMEI Studio."));
        var close = new Button { Content = Localization.Translate("Закрыть"), HorizontalAlignment = HorizontalAlignment.Right, Background = Accent, Foreground = Brushes.White, CornerRadius = new CornerRadius(8), Padding = new Thickness(15, 8) };
        close.Click += (_, _) => dialog.Close();
        panel.Children.Add(close);
        dialog.Content = panel;
        await dialog.ShowDialog(this);
    }

    private async Task ShowOperationHelpAsync(OperationHelpTopic topic)
    {
        var dialog = new Window
        {
            Title = Localization.Translate(topic.Title),
            Width = 800,
            Height = 690,
            MinWidth = 610,
            MinHeight = 440,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Surface,
        };
        var layout = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Thickness(25, 20, 25, 16) };
        var heading = new StackPanel { Spacing = 5 };
        heading.Children.Add(new TextBlock { Text = Localization.Translate(topic.Title), Foreground = Foreground, FontSize = 21, FontWeight = FontWeight.SemiBold });
        heading.Children.Add(new TextBlock { Text = Localization.Translate("Последовательность, команды и сохраняемые файлы"), Foreground = Secondary, FontSize = 12 });
        header.Children.Add(heading);
        var close = new Button
        {
            Content = Localization.Translate("Закрыть"),
            Background = Elevated,
            Foreground = Foreground,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(12, 7),
            VerticalAlignment = VerticalAlignment.Top,
        };
        close.Click += (_, _) => dialog.Close();
        Grid.SetColumn(close, 1);
        header.Children.Add(close);
        layout.Children.Add(header);

        var sections = new StackPanel { Spacing = 18, Margin = new Thickness(25, 9, 25, 25) };
        sections.Children.Add(new TextBlock { Text = Localization.Translate(topic.Introduction), TextWrapping = TextWrapping.Wrap, Foreground = Foreground, FontSize = 13 });
        sections.Children.Add(new TextBlock
        {
            Text = Localization.Translate("<…> обозначает значение конкретной операции. Пароли и приватные ключи не показаны. Это основные команды для объяснения процесса; вводить их вручную не нужно."),
            TextWrapping = TextWrapping.Wrap,
            Foreground = Secondary,
            FontSize = 12,
        });
        foreach (var section in topic.Sections)
        {
            var content = new StackPanel { Spacing = 8 };
            content.Children.Add(new TextBlock { Text = Localization.Translate(section.Title), TextWrapping = TextWrapping.Wrap, Foreground = Accent, FontSize = 15, FontWeight = FontWeight.SemiBold });
            content.Children.Add(new TextBlock { Text = Localization.Translate(section.Body), TextWrapping = TextWrapping.Wrap, Foreground = Foreground, FontSize = 13 });
            if (section.Commands is { Length: > 0 } commands)
            {
                content.Children.Add(new TextBox
                {
                    Text = commands.Trim(),
                    IsReadOnly = true,
                    AcceptsReturn = true,
                    TextWrapping = TextWrapping.Wrap,
                    FontFamily = new FontFamily("Consolas"),
                    FontSize = 11,
                    Background = Canvas,
                    Foreground = Secondary,
                    BorderBrush = Elevated,
                    Padding = new Thickness(11),
                    MinHeight = 42,
                    Height = Math.Min(210, 24 + commands.Count(ch => ch == '\n') * 16),
                });
            }
            sections.Children.Add(new Border { Child = content, Background = Elevated, Padding = new Thickness(16), CornerRadius = new CornerRadius(9) });
        }
        var scroll = new ScrollViewer
        {
            Content = sections,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
        };
        Grid.SetRow(scroll, 1);
        layout.Children.Add(scroll);
        dialog.Content = layout;
        await dialog.ShowDialog(this);
    }

    private Button ActionButton(string label, Func<Task> action, bool prominent)
    {
        var button = new Button
        {
            Content = Localization.Translate(label),
            Background = prominent ? Accent : Elevated,
            Foreground = prominent ? Brushes.White : Foreground,
            CornerRadius = new CornerRadius(8),
            HorizontalAlignment = HorizontalAlignment.Left,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(13, 8),
            Margin = new Thickness(0, 0, 8, 7),
            IsEnabled = !_busy,
        };
        button.Click += async (_, _) =>
        {
            try { await action(); }
            catch (OperationCanceledException) { SetStatus("Операция отменена.", true); }
            catch (Exception error) { SetStatus(error.Message, true); }
        };
        _actionButtons.Add(button);
        return button;
    }

    private async Task ExecuteAsync(ModemOperation operation, string[]? keys) =>
        await ExecuteAsync(operation, keys is null ? null : keys.ToDictionary(key => key, Get));

    private async Task ExecuteAsync(ModemOperation operation, IReadOnlyDictionary<string, string>? parameters)
    {
        if (_busy) return;
        parameters = parameters is null ? new Dictionary<string,string>() : new Dictionary<string,string>(parameters);
        ((Dictionary<string,string>)parameters)["skip_firmware_check"] = Get("skip_firmware_check") == "true" ? "true" : "false";
        if (operation == ModemOperation.PrepareSsh && _snapshot?.ComponentCleanupPending != true && _lastResearchInput != ResearchInputKey())
        {
            await CollectFirmwareResearchAsync(forPreparation: true);
            if (_lastResearchInput != ResearchInputKey()) return;
        }
        if (operation == ModemOperation.EnableDiagnosticAdb && (_snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH"))
        {
            SetStatus(Localization.IsEnglish ? "Use the verified SSH ADB control." : "Используйте проверенное управление ADB по SSH.", true);
            return;
        }
        if (operation == ModemOperation.EnableDiagnosticAdb && (_terminal?.IsConnected == true || _terminalOpening))
        {
            SetStatus("Перед включением ADB отключите интерактивный терминал.", true);
            return;
        }
        var refreshSnapshot = operation != ModemOperation.DiscoverConnections;
        SetBusy(true);
        SetStatus("Выполняется операция на модеме…");
        var preparationStarted = DateTimeOffset.Now;
        var preparationActive = operation is ModemOperation.PrepareSsh or ModemOperation.EnableDiagnosticAdb;
        var readingPreparation = false;
        var preparationTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        preparationTimer.Tick += async (_, _) =>
        {
            if (!preparationActive || readingPreparation) return;
            readingPreparation = true;
            try
            {
                var logs = await _service.GetLogsAsync(_lifetime.Token);
                var latest = logs.LastOrDefault(entry => entry.Timestamp >= preparationStarted &&
                    entry.Message.StartsWith("Подготовка: ", StringComparison.Ordinal));
                if (preparationActive && latest is not null) SetStatus(latest.Message[12..]);
            }
            catch (OperationCanceledException) { }
            finally { readingPreparation = false; }
        };
        if (preparationActive) preparationTimer.Start();
        try
        {
            var result = await _service.RunAsync(new OperationRequest(operation, parameters), _lifetime.Token);
            AdoptPreparedConnection(operation, parameters);
            if (operation is (ModemOperation.PrepareSsh or ModemOperation.CancelComponentCleanup) && result.Success)
            {
                _form["clean_components"] = "false";
                if (_cleanPreparationCheckBox is not null) _cleanPreparationCheckBox.IsChecked = false;
                _form["force_reinstall"] = "false";
                if (_forcePreparationCheckBox is not null) _forcePreparationCheckBox.IsChecked = false;
            }
            preparationActive = false;
            preparationTimer.Stop();
            ClearSecrets(preservePreparation: true);
            SetStatus(result.Message, !result.Success);
            RecordDiagnosticResult(operation, result, parameters);
            if (result.Values is { } values)
            {
                foreach (var item in values)
                    if (item.Key is "feeds" or "ssid" or "password_mode") _form[item.Key] = item.Value;
            }
            if (!string.IsNullOrWhiteSpace(result.Details))
                await ShowMessageAsync(result.Success ? "Результат" : "Ошибка", result.Details);
            if (refreshSnapshot)
            {
                await ReloadSnapshotAsync();
                if (_page == 2 || (_page == 6 && _sections[6] == 1)) await RefreshBackupsAsync();
                if (_page == 5) await RefreshApplicationsAsync();
                if (_page == 6 && _sections[6] == 2) await RefreshLogsAsync();
            }
        }
        catch (OperationCanceledException) { AdoptPreparedConnection(operation, parameters); await ReloadFailedOperationSnapshotAsync(refreshSnapshot); SetStatus("Операция отменена.", true); }
        catch (Exception error) { AdoptPreparedConnection(operation, parameters); await ReloadFailedOperationSnapshotAsync(refreshSnapshot); SetStatus(error.Message, true); await ShowMessageAsync("Ошибка", error.Message); }
        finally { preparationActive = false; preparationTimer.Stop(); ClearSecrets(preservePreparation: true); SetBusy(false); }
    }

    private void AdoptPreparedConnection(ModemOperation operation, IReadOnlyDictionary<string, string>? requested)
    {
        if (operation is not (ModemOperation.PrepareSsh or ModemOperation.CancelComponentCleanup) || requested is null) return;
        // Preparation may establish SSH before a later step fails. Use its saved
        // connection metadata only while the user's original selection is unchanged.
        if (new[] { "host", "username", "key_path", "known_hosts_path" }.Any(key =>
            !requested.TryGetValue(key, out var value) || Get(key) != value)) return;
        var saved = _service.GetConnectionSettings();
        if (saved.Host != requested["host"] || saved.KeyPath.Length == 0 || saved.KnownHostsPath.Length == 0) return;
        _form["port"] = saved.Port.ToString(System.Globalization.CultureInfo.InvariantCulture);
        _form["username"] = saved.Username;
        _form["key_path"] = saved.KeyPath;
        _form["known_hosts_path"] = saved.KnownHostsPath;
    }

    private async Task ReloadFailedOperationSnapshotAsync(bool refreshSnapshot)
    {
        if (!refreshSnapshot || _lifetime.IsCancellationRequested) return;
        try { await ReloadSnapshotAsync(); }
        catch { /* Preserve the original failure; no operation is retried. */ }
    }

    private async Task RefreshAsync(bool reconnectConfigured = false)
    {
        if (_busy) return;
        SetBusy(true);
        try
        {
            string? refreshError = null;
            var settings = _service.GetConnectionSettings();
            var selectedConnectionChanged = Get("host") != settings.Host || Get("key_path") != settings.KeyPath || Get("known_hosts_path") != settings.KnownHostsPath;
            var connectedSsh = _snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH";
            if (reconnectConfigured && (!connectedSsh || selectedConnectionChanged) && Get("key_path").Length > 0 && Get("known_hosts_path").Length > 0)
            {
                // An explicit refresh can retry selected SSH access; it never replays preparation.
                var connected = await _service.RunAsync(new OperationRequest(ModemOperation.Connect,
                    new[] { "host", "username", "key_path", "known_hosts_path", "skip_firmware_check" }.ToDictionary(key => key, Get)), _lifetime.Token);
                if (!connected.Success) refreshError = connected.Message;
            }
            else if (connectedSsh && !selectedConnectionChanged)
            {
                var operation = _page == 0 && _sections[0] == 2 ? ModemOperation.RefreshAgent
                    : _page == 0 && _sections[0] == 3 ? ModemOperation.RefreshLocalization : ModemOperation.RefreshDevice;
                var refreshed = await _service.RunAsync(new OperationRequest(operation, new Dictionary<string,string> { ["skip_firmware_check"] = Get("skip_firmware_check") == "true" ? "true" : "false" }), _lifetime.Token);
                if (!refreshed.Success) refreshError = refreshed.Message;
            }
            else if (connectedSsh && selectedConnectionChanged)
                refreshError = "Для этого действия сначала подключитесь к модему по SSH.";
            await ReloadSnapshotAsync();
            await LoadPageDataAsync();
            SetStatus(refreshError ?? _snapshot?.Status ?? "Состояние обновлено.", refreshError is not null);
        }
        catch (Exception error) { SetStatus(error.Message, true); }
        finally { SetBusy(false); }
    }

    private async Task ReloadSnapshotAsync()
    {
        var prior = _snapshot;
        _snapshot = await _service.GetDeviceSnapshotAsync(_lifetime.Token);
        if (prior?.IsConnected == true && _snapshot.IsConnected &&
            (prior.IpAddress != _snapshot.IpAddress || prior.Serial != _snapshot.Serial)) ClearSecrets();
        if (!_snapshot.IsConnected || _snapshot.Serial != prior?.Serial || _snapshot.IpAddress != prior?.IpAddress || _snapshot.ConnectionMode != prior?.ConnectionMode) { _esimAuthorized = false; _esimSnapshot = null; _esimSelected = null; }
        if (_snapshot.Serial != prior?.Serial || _snapshot.IpAddress != prior?.IpAddress) _launcherPagesDirty = false;
        if (!_launcherPagesDirty && _snapshot.LauncherPages is { } pages)
        {
            _form["pages"] = pages;
            var selected = pages.Split(',', StringSplitOptions.RemoveEmptyEntries);
            _form["page_order"] = string.Join(',', selected.Concat(new[] { "info", "vpn", "esim" }.Except(selected)));
        }
        if (_snapshot.LauncherStyle is { } style) _form["style"] = style;
        if (_snapshot.LauncherMetrics is { } metrics) _form["metrics"] = metrics;
        if (_snapshot.LauncherMetricOrder is { } order) _form["metric_order"] = order;
        if (_snapshot.VpnSsid is { } ssid) _form["ssid"] = ssid;
        if (_snapshot.VpnPasswordMode is { } passwordMode) _form["password_mode"] = passwordMode;
        UpdateConnectionLabels();
        RenderPage();
    }

    private void UpdateConnectionLabels()
    {
        _connection.Text = _snapshot?.IsConnected == true
            ? $"●  {_snapshot?.Model ?? "Модем"} · {_snapshot?.IpAddress ?? _snapshot?.ConnectionMode ?? "подключён"}"
            : $"○  {_snapshot?.Status}";
        _connection.Foreground = _snapshot?.IsConnected == true ? Accent : Warn;
        _sidebarConnection.Text = _snapshot?.IsConnected == true
            ? "● Подключено · " + (_snapshot?.ConnectionMode ?? "модем")
            : "○ Нет подключения";
        _sidebarConnection.Foreground = _snapshot?.IsConnected == true ? Accent : Warn;
        _connection.Text = Localization.Translate(_connection.Text ?? "");
        _sidebarConnection.Text = Localization.Translate(_sidebarConnection.Text ?? "");
    }

    private async Task LoadPageDataAsync()
    {
        if (_page == 5 && _sections[5] == 2 && !_busy && !_terminalAutoAttempted && _snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH")
        {
            _terminalAutoAttempted = true;
            await OpenTerminalAsync();
        }
        if (_page == 2 && _sections[2] == 1 || _page == 6 && _sections[6] == 1)
            await RefreshBackupsAsync();
        else if (_page == 5 && _sections[5] != 2)
            await RefreshApplicationsAsync();
        else if (_page == 6 && _sections[6] == 2)
            await RefreshLogsAsync();
    }

    private async Task RefreshBackupsAsync()
    {
        try { _backups = await _service.ListBackupsAsync(_lifetime.Token); RenderPage(); }
        catch (Exception error) { SetStatus(error.Message, true); }
    }

    private void CatalogChanged() => Dispatcher.UIThread.Post(() =>
    {
        if (_page == 5 && _sections[5] == 1) RenderPage();
    });

    private async Task RefreshApplicationsAsync()
    {
        try { _applications = await _service.ListApplicationsAsync(_lifetime.Token); RenderPage(); }
        catch (Exception error) { SetStatus(error.Message, true); }
    }

    private async Task RefreshLogsAsync()
    {
        try { _logs = await _service.GetLogsAsync(_lifetime.Token); RenderPage(); }
        catch (Exception error) { SetStatus(error.Message, true); }
    }

    private bool CanPrepare() => !_busy && _terminal?.IsConnected != true && !_terminalOpening &&
        _snapshot?.AdbActivationPending != true && (_snapshot?.PreparationPending == true || Get("force_reinstall") == "true" ||
        !(_snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH"));

    private bool CanChangePreparationMode() => !_busy && _terminal?.IsConnected != true && !_terminalOpening &&
        _snapshot?.ComponentCleanupPending != true && _snapshot?.AdbActivationPending != true;

    private bool CanSelectCleanPreparation() => !_busy && _terminal?.IsConnected != true && !_terminalOpening &&
        _snapshot?.ComponentCleanupPending != true && _snapshot?.AdbActivationPending != true;

    private void SetBusy(bool busy)
    {
        _busy = busy;
        foreach (var button in _actionButtons) button.IsEnabled = !busy;
        if (_preparationButton is not null)
            _preparationButton.IsEnabled = CanPrepare();
        if (_cancelCleanupButton is not null) _cancelCleanupButton.IsEnabled = CanPrepare();
        if (_skipFirmwareCheckBox is not null) _skipFirmwareCheckBox.IsEnabled = !busy && _terminal?.IsConnected != true && !_terminalOpening;
        if (_forcePreparationCheckBox is not null) _forcePreparationCheckBox.IsEnabled = CanChangePreparationMode();
        if (_cleanPreparationCheckBox is not null) _cleanPreparationCheckBox.IsEnabled = CanSelectCleanPreparation();
        if (!busy && _page == 5 && _sections[5] == 2 && !_terminalAutoAttempted)
            _ = LoadPageDataAsync();
        UpdateDiagnosticAvailability();
        UpdateEsimAvailability();
        UpdateCustomAgentAvailability();
    }

    private void ClearSecrets(bool discardFields = false, bool preservePreparation = false)
    {
        ClearEsimSecrets();
        if (!preservePreparation)
        {
            _customAgent = null; _customAgentContext = null;
            _preparationSecrets.Clear(); InvalidateBackupKeyCheck();
            _form["clean_components"] = "false";
            if (_cleanPreparationCheckBox is not null) _cleanPreparationCheckBox.IsChecked = false;
            _form["force_reinstall"] = "false";
            if (_forcePreparationCheckBox is not null) _forcePreparationCheckBox.IsChecked = false;
        }
        else foreach (var field in _secretFields.Where(field => IsPreparationSecret(field.Key)))
        {
            var value = field.Value.Text ?? "";
            if (value.Length == 0) _preparationSecrets.Remove(field.Key); else _preparationSecrets[field.Key] = value;
        }
        var fields = _secretFields.ToArray();
        // Detach old controls before clearing them, so their events cannot erase retained input.
        if (discardFields) _secretFields.Clear();
        foreach (var field in fields)
            if (discardFields || !preservePreparation || !IsPreparationSecret(field.Key)) field.Value.Text = "";
    }

    private void SetStatus(string message, bool error = false)
    {
        _status.Text = Localization.Translate(message);
        _status.Foreground = error ? Warn : Secondary;
    }

    private async Task<bool> ConfirmAsync(string title, string message)
    {
        var dialog = new Window
        {
            Title = Localization.Translate(title),
            Width = 430,
            Height = 185,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Surface,
        };
        var panel = new StackPanel { Spacing = 17, Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = Localization.Translate(message), Foreground = Foreground, TextWrapping = TextWrapping.Wrap });
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = Localization.Translate("Отмена"), Margin = new Thickness(0, 0, 8, 0) };
        cancel.Click += (_, _) => dialog.Close(false);
        var accept = new Button { Content = Localization.Translate("Продолжить"), Background = Accent, Foreground = Brushes.White };
        accept.Click += (_, _) => dialog.Close(true);
        actions.Children.Add(cancel);
        actions.Children.Add(accept);
        panel.Children.Add(actions);
        dialog.Content = panel;
        return await dialog.ShowDialog<bool>(this);
    }

    private async Task ShowMessageAsync(string title, string message)
    {
        var dialog = new Window
        {
            Title = Localization.Translate(title),
            Width = 520,
            Height = 310,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Surface,
        };
        var panel = new StackPanel { Spacing = 15, Margin = new Thickness(20) };
        panel.Children.Add(new ScrollViewer
        {
            Content = new TextBlock { Text = Localization.Translate(message), TextWrapping = TextWrapping.Wrap, Foreground = Foreground },
            Height = 225,
        });
        var close = new Button { Content = Localization.Translate("Закрыть"), HorizontalAlignment = HorizontalAlignment.Right };
        close.Click += (_, _) => dialog.Close();
        panel.Children.Add(close);
        dialog.Content = panel;
        await dialog.ShowDialog(this);
    }

    private async Task ShutdownAsync()
    {
        ClearSecrets(discardFields: true);
        VerifiedCatalogStore.Shared.Changed -= CatalogChanged;
        _lifetime.Cancel();
        try { await CloseTerminalAsync(); }
        catch { /* Window is already closing. */ }
        _lifetime.Dispose();
    }
}
