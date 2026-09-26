using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using ZteImeiStudio.Windows.Core;

namespace ZteImeiStudio.Windows;

public sealed class MainWindow : Window
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
        new("Подготовка модема", "Подключение, агент и русский интерфейс", "⌁", ["Подключение и настройка", "Агент", "Русификация"]),
        new("Launcher", "Экран модема и его плитки", "▣", ["Информация о модеме", "Управление VPN"]),
        new("IMEI", "Чтение, смена и резервные копии", "◈", ["Смена IMEI", "Бэкапы IMEI"]),
        new("TTL", "Правила исходящего и входящего TTL", "⇄", ["Настройки TTL"]),
        new("VPN", "Компоненты VPN на модеме", "◇", ["Состояние VPN"]),
        new("Приложения", "Установленные пакеты и каталог", "▦", ["Установлено", "Каталог", "Terminal"]),
        new("Администрирование", "Доступы, бэкапы и журнал", "⚙", ["Доступы", "Бэкапы", "Журнал действий"]),
        new("О модеме", "Устройство, память и диагностика", "ⓘ", ["Об устройстве", "Память", "Диагностика"]),
    ];

    private static readonly IBrush Canvas = Brush("#101418");
    private static readonly IBrush Sidebar = Brush("#151B20");
    private static readonly IBrush Surface = Brush("#1B2429");
    private static readonly IBrush Elevated = Brush("#253137");
    private static readonly new IBrush Foreground = Brush("#EAF1F0");
    private static readonly IBrush Secondary = Brush("#96A6AA");
    private static readonly IBrush Accent = Brush("#58D4BB");
    private static readonly IBrush Warn = Brush("#E9B86D");

    private readonly IModemService _service;
    private readonly StackPanel _sidebarItems = new() { Spacing = 5 };
    private readonly StackPanel _body = new() { Spacing = 18 };
    private readonly TextBlock _status = new() { Foreground = Secondary, FontSize = 12 };
    private readonly TextBlock _connection = new() { Foreground = Accent, FontSize = 12 };
    private readonly TextBlock _sidebarConnection = new() { Foreground = Warn, FontSize = 12, TextWrapping = TextWrapping.Wrap };
    private readonly List<Button> _actionButtons = [];
    private Button? _refreshButton;
    private Button? _preparationButton;
    private readonly Dictionary<string, string> _form = new(StringComparer.Ordinal);
    private readonly Dictionary<string, TextBox> _secretFields = new(StringComparer.Ordinal);
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
    private TextBox? _terminalOutput;
    private TextBox? _terminalInput;
    private string _terminalText = "";
    private bool _busy;
    private int _page;

    public MainWindow(IModemService service)
    {
        _service = service;
        Title = "ZTE IMEI Studio — Windows x64";
        Width = 1120;
        Height = 790;
        MinWidth = 880;
        MinHeight = 620;
        Background = Canvas;

        var layout = new Grid { ColumnDefinitions = new ColumnDefinitions("232,*") };
        var side = new Border { Background = Sidebar, Padding = new Thickness(16, 23, 16, 16) };
        var sideStack = new StackPanel { Spacing = 12 };
        sideStack.Children.Add(new TextBlock
        {
            Text = "⌁  ZTE",
            Foreground = Accent,
            FontSize = 24,
            FontWeight = FontWeight.SemiBold,
            Margin = new Thickness(6, 0, 0, 0),
        });
        sideStack.Children.Add(new TextBlock
        {
            Text = "IMEI STUDIO  ·  WINDOWS",
            Foreground = Secondary,
            FontSize = 10,
            Margin = new Thickness(7, -9, 0, 17),
        });
        sideStack.Children.Add(_sidebarItems);
        sideStack.Children.Add(new Border { Height = 1, Background = Elevated, Margin = new Thickness(0, 18, 0, 7) });
        sideStack.Children.Add(_sidebarConnection);
        sideStack.Children.Add(new TextBlock
        {
            Text = "Локальное управление модемом",
            Foreground = Secondary,
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(6, 0, 6, 0),
        });
        side.Child = sideStack;
        layout.Children.Add(side);

        var right = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        Grid.SetColumn(right, 1);
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Thickness(29, 19, 29, 17) };
        var titleStack = new StackPanel { Spacing = 4 };
        titleStack.Children.Add(new TextBlock
        {
            Text = "ZTE IMEI Studio",
            Foreground = Foreground,
            FontSize = 21,
            FontWeight = FontWeight.SemiBold,
        });
        titleStack.Children.Add(_connection);
        header.Children.Add(titleStack);
        var refresh = ActionButton("Обновить", async () => await RefreshAsync(), false);
        _refreshButton = refresh;
        Grid.SetColumn(refresh, 1);
        refresh.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(refresh);
        right.Children.Add(header);

        var scroller = new ScrollViewer
        {
            Content = _body,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        };
        _body.Margin = new Thickness(29, 12, 29, 28);
        Grid.SetRow(scroller, 1);
        right.Children.Add(scroller);

        var footer = new Border { Background = Sidebar, Padding = new Thickness(28, 11) };
        _status.Text = "Готово к подключению";
        footer.Child = _status;
        Grid.SetRow(footer, 2);
        right.Children.Add(footer);
        layout.Children.Add(right);
        Content = layout;

        _form["host"] = "192.168.0.1";
        _form["username"] = "root";
        _form["mode"] = "Автоматически";
        _form["outbound_ttl"] = "64";
        _form["incoming_delta"] = "1";
        _form["style"] = "list";
        _form["metrics"] = "cpu,signal,network,carriers,cpu_temp,modem_temp";
        _form["metric_order"] = string.Join(',', DisplayMetrics.Select(metric => metric.Id));
        _form["password_mode"] = "main";
        _form["ssid"] = "ZTE-VPN";
        RenderSidebar();
        RenderPage();
        Opened += async (_, _) => await RefreshAsync();
        Closed += async (_, _) => await ShutdownAsync();
    }

    private static IBrush Brush(string hex) => new SolidColorBrush(Color.Parse(hex));

    private void RenderSidebar()
    {
        _sidebarItems.Children.Clear();
        for (var i = 0; i < Pages.Length; i++)
        {
            var index = i;
            var selected = i == _page;
            var button = new Button
            {
                Content = $"{Pages[i].Icon}   {Pages[i].Title}",
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
                _page = index;
                RenderSidebar();
                RenderPage();
                await LoadPageDataAsync();
            };
            _sidebarItems.Children.Add(button);
        }
    }

    private void RenderPage()
    {
        _body.Children.Clear();
        _metricRows = null;
        _previewRows = null;
        _metricCount = null;
        ClearSecrets();
        _secretFields.Clear();
        _actionButtons.Clear();
        _preparationButton = null;
        if (_refreshButton is not null) _actionButtons.Add(_refreshButton);
        var page = Pages[_page];
        _body.Children.Add(new TextBlock
        {
            Text = page.Title,
            Foreground = Foreground,
            FontSize = 29,
            FontWeight = FontWeight.SemiBold,
        });
        _body.Children.Add(new TextBlock
        {
            Text = page.Subtitle,
            Foreground = Secondary,
            FontSize = 13,
            Margin = new Thickness(0, -12, 0, 3),
        });
        if (page.Sections.Length > 1)
        {
            var tabs = new WrapPanel { ItemHeight = 36, Orientation = Orientation.Horizontal };
            for (var i = 0; i < page.Sections.Length; i++)
            {
                var section = i;
                var tab = new Button
                {
                    Content = page.Sections[i],
                    Background = i == _sections[_page] ? Elevated : Brushes.Transparent,
                    Foreground = i == _sections[_page] ? Accent : Secondary,
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(12, 8),
                    Margin = new Thickness(0, 0, 6, 6),
                };
                tab.Click += async (_, _) =>
                {
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
        }
    }

    private void BuildPreparation()
    {
        switch (_sections[0])
        {
            case 0:
                AddCard("Подключение к модему", "Адрес и учётные данные используются для выбранного способа подключения.", panel =>
                {
                    panel.Children.Add(Field("Адрес модема", "host", "192.168.0.1"));
                    panel.Children.Add(Field("Пользователь SSH", "username", "root"));
                    panel.Children.Add(Field("Пароль веб-интерфейса", "web_password", "Введите пароль", secret: true));
                    panel.Children.Add(Field("Пароль агента / SSH", "agent_password", "Введите пароль", secret: true));
                    panel.Children.Add(Field("Backup-key suffix", "backup_key_suffix", "Суффикс ключа резервной копии вашей прошивки", secret: true));
                    panel.Children.Add(Muted("Суффикс нужен только для предварительной подготовки через Web; он не включён в публичную сборку и не сохраняется."));
                    panel.Children.Add(Muted("Режим подключения"));
                    var modes = new ComboBox
                    {
                        ItemsSource = new[] { "Автоматически", "SSH", "ADB" },
                        SelectedIndex = Get("mode") switch { "SSH" => 1, "ADB" => 2, _ => 0 },
                        MinWidth = 220,
                        HorizontalAlignment = HorizontalAlignment.Left,
                    };
                    modes.SelectionChanged += (_, _) => _form["mode"] = modes.SelectedIndex switch
                    {
                        1 => "SSH", 2 => "ADB", _ => "Автоматически",
                    };
                    panel.Children.Add(modes);
                    panel.Children.Add(FileField("Существующий SSH private key", "key_path", "Использовать локальный ключ"));
                    panel.Children.Add(FileField("Существующий known_hosts", "known_hosts_path", "Использовать локальный known_hosts"));
                    var skipCheck = new CheckBox
                    {
                        Content = "Пропустить проверку прошивки",
                        IsChecked = Get("skip_firmware_check") == "true",
                        Foreground = Warn,
                    };
                    skipCheck.IsCheckedChanged += (_, _) => _form["skip_firmware_check"] = skipCheck.IsChecked == true ? "true" : "false";
                    panel.Children.Add(skipCheck);
                    panel.Children.Add(Actions(
                        ("Проверить подключения", ModemOperation.DiscoverConnections, ["host", "web_password", "agent_password", "key_path", "known_hosts_path"]),
                        ("Подключиться", ModemOperation.Connect, ["host", "username", "web_password", "agent_password", "mode", "skip_firmware_check", "key_path", "known_hosts_path"])));
                    var preparation = new WrapPanel { Orientation = Orientation.Horizontal };
                    _preparationButton = ActionButton("Выполнить предварительную подготовку модема", async () =>
                        await ExecuteAsync(ModemOperation.PrepareSsh, ["host", "username", "web_password", "agent_password", "backup_key_suffix", "skip_firmware_check", "key_path", "known_hosts_path"]), true);
                    _preparationButton.IsEnabled = !_busy && !(_snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH");
                    preparation.Children.Add(_preparationButton);
                    preparation.Children.Add(OperationInfoButton(OperationHelpContent.Preparation));
                    panel.Children.Add(preparation);
                });
                AddSnapshotCard();
                break;
            case 1:
                AddCard("Агент модема", "Проверка, установка и откат штатного агента.", panel =>
                {
                    panel.Children.Add(Actions(
                        ("Проверить агент", ModemOperation.RefreshAgent, null),
                        ("Установить / обновить", ModemOperation.InstallAgent, null),
                        ("Восстановить предыдущий", ModemOperation.RestoreAgent, null)));
                    panel.Children.Add(ValueLine("Состояние", _snapshot?.Agent));
                });
                break;
            case 2:
                AddCard("Русский интерфейс", "Пакет русификации экрана устанавливается на модем.", panel =>
                {
                    panel.Children.Add(Actions(
                        ("Проверить", ModemOperation.RefreshLocalization, null),
                        ("Установить", ModemOperation.InstallLocalization, null),
                        ("Восстановить предыдущий", ModemOperation.RestoreLocalization, null)));
                });
                break;
        }
    }

    private void BuildLauncher()
    {
        AddCard("Плитки на экране модема", "Две дополнительные страницы штатного лаунчера: информация о модеме и управление VPN.", panel =>
        {
            panel.Children.Add(ValueLine("Состояние", _snapshot?.Launcher));
            panel.Children.Add(Actions(
                ("Проверить лаунчер", ModemOperation.RefreshLauncher, null),
                ("Установить / обновить", ModemOperation.InstallLauncher, null)));
            panel.Children.Add(Muted("Установка может перезапустить экран модема. Состав и порядок информационных показателей сохраняются отдельно."));
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
                    ItemsSource = new[] { "Пароль основной сети", "Новый пароль", "Сохранить текущий" },
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
            Text = "ПРЕДПРОСМОТР ЭКРАНА", Foreground = Secondary,
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
            Text = vpn is null ? "SSID не прочитан" :
                string.IsNullOrWhiteSpace(vpn.Ssid) ? "Сеть не настроена" : vpn.Ssid,
            Foreground = Secondary, FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        screen.Children.Add(VpnPreviewRow("Wi-Fi с VPN", vpn?.Enabled == true ? "Вкл" : "Выкл", vpn?.Enabled == true));
        screen.Children.Add(new TextBlock
        {
            Text = "Профиль VPN", Foreground = Foreground, FontSize = 14,
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
            Text = vpn is null ? "Состояние не прочитано" :
                !vpn.Installed ? "Установите компоненты VPN" :
                !vpn.Configured ? "Сеть ещё не настроена" :
                !vpn.Enabled ? "Wi-Fi с VPN выключен" :
                vpn.CoreRunning ? "Ядро VPN запущено" : "Проверьте состояние VPN",
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
            Text = title, Foreground = active ? Accent : Foreground,
            FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        if (detail is not null)
        {
            var value = new TextBlock
            {
                Text = detail, Foreground = active ? Accent : Secondary,
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
            Text = "ПРЕДПРОСМОТР ЭКРАНА", Foreground = Secondary, FontSize = 10,
            FontWeight = FontWeight.SemiBold,
        });
        previewColumn.Children.Add(Muted("Тип страницы на модеме"));
        var styles = new ComboBox
        {
            ItemsSource = new[] { "Список", "Плитки" },
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
            Text = "О модеме", Foreground = Foreground, FontSize = 20,
            FontWeight = FontWeight.SemiBold,
        });
        screen.Children.Add(new TextBlock { Text = "Данные модема", Foreground = Secondary, FontSize = 11 });
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
            _metricCount.Text = $"ПОКАЗАТЕЛИ  ·  {enabled.Count} из {DisplayMetrics.Length}";
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
                Text = metric.Title, Foreground = selected ? Foreground : Secondary,
                FontSize = 12, FontWeight = FontWeight.Medium,
                TextWrapping = TextWrapping.Wrap,
            });
            label.Children.Add(new TextBlock
            {
                Text = metric.Detail, Foreground = Secondary, FontSize = 10,
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
                ToolTip.SetTip(arrow, delta < 0 ? "Переместить выше" : "Переместить ниже");
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
            ToolTip.SetTip(handle, "Перетащить для изменения порядка");
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
            Text = tile ? metric.TileTitle : metric.Title,
            Foreground = Secondary, FontSize = tile ? 11 : 10,
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(new TextBlock
        {
            Text = metric.Example, Foreground = Foreground,
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
            AddCard("Terminal и opkg", "Полный терминал модема доступен ниже. Изолированный opkg работает в /data; штатные системные пакеты не изменяются.", panel =>
            {
                panel.Children.Add(Muted("Платформа проверенной прошивки B31: OpenWrt 23.05.4, aarch64_cortex-a53. Сначала установите адаптер, прочитайте источники и выполните opkg update. Затем можно выполнить opkg list, opkg install <пакет> или opkg remove <пакет>."));
                panel.Children.Add(Actions(
                    ("Проверить opkg", ModemOperation.RefreshOpkg, null),
                    ("Установить адаптер", ModemOperation.InstallOpkg, null),
                    ("Удалить адаптер", ModemOperation.RemoveOpkg, null)));
                panel.Children.Add(Field("Команда opkg", "command", "opkg list-installed"));
                panel.Children.Add(Actions(("Выполнить", ModemOperation.RunOpkgCommand, ["command"])));
            });
            AddCard("Источники пакетов opkg", "Редактор приватного адаптера. Одна запись src/gz на строку.", panel =>
            {
                panel.Children.Add(ActionButton("Прочитать с модема", async () => await ExecuteAsync(ModemOperation.LoadOpkgFeeds, (string[]?)null), false));
                panel.Children.Add(Field("Источники", "feeds", "src/gz имя https://адрес/каталога", multiline: true));
                panel.Children.Add(ActionButton("Сохранить источники", async () => await ExecuteAsync(ModemOperation.SaveOpkgFeeds, ["feeds"]), true));
            });
            AddTerminalCard();
            return;
        }
        AddCard(_sections[5] == 0 ? "Установленные приложения" : "Каталог приложений",
            "Каждое приложение показывает текущий статус на модеме и доступное действие.", panel =>
        {
            panel.Children.Add(Actions(("Обновить список", ModemOperation.RefreshApplications, null)));
            var apps = _applications.Where(app => _sections[5] == 0
                ? app.Installed
                : !app.Id.StartsWith("stock:", StringComparison.OrdinalIgnoreCase)).ToList();
            if (apps.Count == 0)
            {
                panel.Children.Add(Muted("Список пока пуст. Подключитесь и нажмите «Обновить список»."));
                return;
            }
            foreach (var app in apps)
            {
                var isStock = app.Id.StartsWith("stock:", StringComparison.OrdinalIgnoreCase);
                var isSsclash = app.Id.Contains("ssclash", StringComparison.OrdinalIgnoreCase) ||
                    app.Name.Contains("SSClash", StringComparison.OrdinalIgnoreCase);
                var row = new StackPanel { Spacing = 5 };
                row.Children.Add(new TextBlock { Text = app.Name + (app.Version is null ? "" : $" · {app.Version}"), Foreground = Foreground, FontWeight = FontWeight.SemiBold });
                row.Children.Add(Muted(app.Description ?? app.Id));
                if (isStock) row.Children.Add(Muted("Штатное приложение модема"));
                else row.Children.Add(Muted(app.StatusKnown
                    ? app.Installed ? "● Установлено" : "○ Не установлено"
                    : "○ Состояние не проверено"));
                if (isSsclash && !app.Installed)
                {
                    row.Children.Add(Muted("При установке SSClash-Go загружается из официального релиза GitHub; проверьте его лицензию в Resources/Applications."));
                    row.Children.Add(Field("Пароль SSClash-Go", "ssclash_password", "От 8 до 128 символов", secret: true));
                    row.Children.Add(Field("Повторите пароль", "ssclash_confirmation", "Повторите пароль", secret: true));
                }
                if (!isStock && app.StatusKnown) row.Children.Add(ActionButton(app.Installed ? "Удалить" : isSsclash ? "Скачать и установить" : "Установить", async () =>
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
                }, !app.Installed));
                panel.Children.Add(new Border
                {
                    Child = row,
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
                    panel.Children.Add(Actions(("Проверить доступы", ModemOperation.RefreshAccess, null)));
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
            case 2:
                AddCard("Диагностика", "Сбор состояния устройства и экспорт диагностических данных.", panel =>
                {
                    panel.Children.Add(Actions(
                        ("Проверить", ModemOperation.RefreshDiagnostics, null),
                        ("Экспортировать журнал", ModemOperation.ExportDiagnostics, null)));
                    panel.Children.Add(ActionButton("Перезагрузить модем", async () =>
                    {
                        if (await ConfirmAsync("Перезагрузить модем?", "Соединение будет временно потеряно."))
                            await ExecuteAsync(ModemOperation.RebootDevice, (string[]?)null);
                    }, false));
                });
                break;
        }
    }

    private void AddSnapshotCard()
    {
        AddCard("Состояние устройства", "Данные обновляются при подключении и по кнопке «Обновить». ", panel =>
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
            buttons.Children.Add(ActionButton("Открыть Terminal", OpenTerminalAsync, true));
            buttons.Children.Add(ActionButton("Ctrl+C", async () =>
            {
                if (_terminal?.IsConnected == true) await _terminal.SendAsync("\u0003", _lifetime.Token);
            }, false));
            buttons.Children.Add(ActionButton("Отключить", CloseTerminalAsync, false));
            panel.Children.Add(buttons);
            _terminalOutput = new TextBox
            {
                Text = _terminalText,
                IsReadOnly = true,
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                MinHeight = 180,
                MaxHeight = 360,
                FontFamily = new FontFamily("Consolas, Cascadia Mono, monospace"),
                Background = Canvas,
                Foreground = Foreground,
            };
            panel.Children.Add(_terminalOutput);
            _terminalInput = new TextBox { Watermark = "Команда", Background = Elevated, Foreground = Foreground };
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
        try
        {
            await CloseTerminalAsync();
            _terminal = await _service.OpenTerminalAsync(_lifetime.Token);
            _terminal.OutputReceived += TerminalOutputReceived;
            SetStatus("Терминал подключён.");
        }
        catch (Exception error) { SetStatus(error.Message, true); }
    }

    private void TerminalOutputReceived(object? sender, TerminalDataEventArgs args) =>
        Dispatcher.UIThread.Post(() =>
        {
            _terminalText += args.Text;
            if (_terminalText.Length > 100_000) _terminalText = _terminalText[^100_000..];
            if (_terminalOutput is not null)
            {
                _terminalOutput.Text = _terminalText;
                _terminalOutput.CaretIndex = _terminalText.Length;
            }
        });

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

    private async Task CloseTerminalAsync()
    {
        if (_terminal is null) return;
        _terminal.OutputReceived -= TerminalOutputReceived;
        await _terminal.DisposeAsync();
        _terminal = null;
        SetStatus("Терминал отключён.");
    }

    private void AddCard(string title, string description, Action<StackPanel> build)
    {
        var panel = new StackPanel { Spacing = 13 };
        panel.Children.Add(new TextBlock { Text = title, Foreground = Foreground, FontSize = 18, FontWeight = FontWeight.SemiBold });
        panel.Children.Add(Muted(description));
        build(panel);
        _body.Children.Add(new Border
        {
            Background = Surface,
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(20),
            Child = panel,
        });
    }

    private static TextBlock Muted(string value) => new()
    {
        Text = value,
        Foreground = Secondary,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
    };

    private static Control ValueLine(string label, string? value)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("170,*") };
        row.Children.Add(new TextBlock { Text = label, Foreground = Secondary, FontSize = 12 });
        var data = new TextBlock { Text = string.IsNullOrWhiteSpace(value) ? "—" : value, Foreground = Foreground, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(data, 1);
        row.Children.Add(data);
        return row;
    }

    private Control Field(string label, string key, string watermark, bool secret = false, bool multiline = false)
    {
        var stack = new StackPanel { Spacing = 5 };
        stack.Children.Add(new TextBlock { Text = label, Foreground = Secondary, FontSize = 12 });
        var input = new TextBox
        {
            Text = secret ? "" : Get(key),
            Watermark = watermark,
            Background = Elevated,
            Foreground = Foreground,
            MaxWidth = 480,
            HorizontalAlignment = HorizontalAlignment.Left,
            MinWidth = 300,
        };
        if (secret) input.PasswordChar = '●';
        if (multiline)
        {
            input.AcceptsReturn = true;
            input.MinHeight = 140;
            input.MaxWidth = 700;
        }
        if (secret) _secretFields[key] = input;
        else input.TextChanged += (_, _) => _form[key] = input.Text ?? "";
        stack.Children.Add(input);
        return stack;
    }

    private Control FileField(string label, string key, string watermark)
    {
        var stack = new StackPanel { Spacing = 5 };
        stack.Children.Add(Muted(label));
        var row = new WrapPanel();
        var input = new TextBox
        {
            Text = Get(key), Watermark = watermark, Background = Elevated, Foreground = Foreground,
            MinWidth = 300, MaxWidth = 560, Margin = new Thickness(0, 0, 8, 0),
        };
        input.TextChanged += (_, _) => _form[key] = input.Text ?? "";
        row.Children.Add(input);
        row.Children.Add(ActionButton("Обзор…", async () =>
        {
            var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = label, AllowMultiple = false,
            });
            if (files.Count == 1 && files[0].Path.IsFile)
                input.Text = files[0].Path.LocalPath;
        }, false));
        stack.Children.Add(row);
        return stack;
    }

    private string Get(string key) => _secretFields.TryGetValue(key, out var secret)
        ? secret.Text ?? ""
        : _form.GetValueOrDefault(key, "").Trim();

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
        ToolTip.SetTip(button, topic.AccessibleName);
        button.Click += async (_, _) => await ShowOperationHelpAsync(topic);
        return button;
    }

    private async Task ShowOperationHelpAsync(OperationHelpTopic topic)
    {
        var dialog = new Window
        {
            Title = topic.Title,
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
        heading.Children.Add(new TextBlock { Text = topic.Title, Foreground = Foreground, FontSize = 21, FontWeight = FontWeight.SemiBold });
        heading.Children.Add(new TextBlock { Text = "Последовательность, команды и сохраняемые файлы", Foreground = Secondary, FontSize = 12 });
        header.Children.Add(heading);
        var close = new Button
        {
            Content = "Закрыть",
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
        sections.Children.Add(new TextBlock { Text = topic.Introduction, TextWrapping = TextWrapping.Wrap, Foreground = Foreground, FontSize = 13 });
        sections.Children.Add(new TextBlock
        {
            Text = "<…> обозначает значение конкретной операции. Пароли и приватные ключи не показаны. Это основные команды для объяснения процесса; вводить их вручную не нужно.",
            TextWrapping = TextWrapping.Wrap,
            Foreground = Secondary,
            FontSize = 12,
        });
        foreach (var section in topic.Sections)
        {
            var content = new StackPanel { Spacing = 8 };
            content.Children.Add(new TextBlock { Text = section.Title, TextWrapping = TextWrapping.Wrap, Foreground = Accent, FontSize = 15, FontWeight = FontWeight.SemiBold });
            content.Children.Add(new TextBlock { Text = section.Body, TextWrapping = TextWrapping.Wrap, Foreground = Foreground, FontSize = 13 });
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
            Content = label,
            Background = prominent ? Accent : Elevated,
            Foreground = prominent ? Canvas : Foreground,
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
        var preserveSecrets = operation == ModemOperation.DiscoverConnections;
        SetBusy(true);
        SetStatus("Выполняется операция на модеме…");
        try
        {
            var result = await _service.RunAsync(new OperationRequest(operation, parameters), _lifetime.Token);
            if (!preserveSecrets) ClearSecrets();
            SetStatus(result.Message, !result.Success);
            if (result.Values is { } values)
            {
                foreach (var item in values)
                    if (item.Key is "feeds" or "ssid" or "password_mode") _form[item.Key] = item.Value;
            }
            if (!string.IsNullOrWhiteSpace(result.Details))
                await ShowMessageAsync(result.Success ? "Результат" : "Ошибка", result.Details);
            if (result.Success && !preserveSecrets)
            {
                await ReloadSnapshotAsync();
                if (_page == 2 || (_page == 6 && _sections[6] == 1)) await RefreshBackupsAsync();
                if (_page == 5) await RefreshApplicationsAsync();
                if (_page == 6 && _sections[6] == 2) await RefreshLogsAsync();
            }
        }
        catch (OperationCanceledException) { SetStatus("Операция отменена.", true); }
        catch (Exception error) { SetStatus(error.Message, true); await ShowMessageAsync("Ошибка", error.Message); }
        finally { if (!preserveSecrets) ClearSecrets(); SetBusy(false); }
    }

    private async Task RefreshAsync()
    {
        if (_busy) return;
        SetBusy(true);
        try
        {
            string? refreshError = null;
            if (_snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH")
            {
                var refreshed = await _service.RunAsync(new OperationRequest(ModemOperation.RefreshDevice), _lifetime.Token);
                if (!refreshed.Success) refreshError = refreshed.Message;
            }
            await ReloadSnapshotAsync();
            await LoadPageDataAsync();
            SetStatus(refreshError ?? _snapshot?.Status ?? "Состояние обновлено.", refreshError is not null);
        }
        catch (Exception error) { SetStatus(error.Message, true); }
        finally { SetBusy(false); }
    }

    private async Task ReloadSnapshotAsync()
    {
        _snapshot = await _service.GetDeviceSnapshotAsync(_lifetime.Token);
        if (_snapshot.LauncherStyle is { } style) _form["style"] = style;
        if (_snapshot.LauncherMetrics is { } metrics) _form["metrics"] = metrics;
        if (_snapshot.LauncherMetricOrder is { } order) _form["metric_order"] = order;
        if (_snapshot.VpnSsid is { } ssid) _form["ssid"] = ssid;
        if (_snapshot.VpnPasswordMode is { } passwordMode) _form["password_mode"] = passwordMode;
        _connection.Text = _snapshot.IsConnected
            ? $"●  {_snapshot.Model ?? "Модем"} · {_snapshot.IpAddress ?? _snapshot.ConnectionMode ?? "подключён"}"
            : $"○  {_snapshot.Status}";
        _connection.Foreground = _snapshot.IsConnected ? Accent : Warn;
        _sidebarConnection.Text = _snapshot.IsConnected
            ? "● Подключено · " + (_snapshot.ConnectionMode ?? "модем")
            : "○ Нет подключения";
        _sidebarConnection.Foreground = _snapshot.IsConnected ? Accent : Warn;
        RenderPage();
    }

    private async Task LoadPageDataAsync()
    {
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

    private void SetBusy(bool busy)
    {
        _busy = busy;
        foreach (var button in _actionButtons) button.IsEnabled = !busy;
        if (_preparationButton is not null)
            _preparationButton.IsEnabled = !busy && !(_snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH");
    }

    private void ClearSecrets()
    {
        foreach (var input in _secretFields.Values) input.Text = "";
    }

    private void SetStatus(string message, bool error = false)
    {
        _status.Text = message;
        _status.Foreground = error ? Warn : Secondary;
    }

    private async Task<bool> ConfirmAsync(string title, string message)
    {
        var dialog = new Window
        {
            Title = title,
            Width = 430,
            Height = 185,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Surface,
        };
        var panel = new StackPanel { Spacing = 17, Margin = new Thickness(22) };
        panel.Children.Add(new TextBlock { Text = message, Foreground = Foreground, TextWrapping = TextWrapping.Wrap });
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Отмена", Margin = new Thickness(0, 0, 8, 0) };
        cancel.Click += (_, _) => dialog.Close(false);
        var accept = new Button { Content = "Продолжить", Background = Accent, Foreground = Canvas };
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
            Title = title,
            Width = 520,
            Height = 310,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Surface,
        };
        var panel = new StackPanel { Spacing = 15, Margin = new Thickness(20) };
        panel.Children.Add(new ScrollViewer
        {
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, Foreground = Foreground },
            Height = 225,
        });
        var close = new Button { Content = "Закрыть", HorizontalAlignment = HorizontalAlignment.Right };
        close.Click += (_, _) => dialog.Close();
        panel.Children.Add(close);
        dialog.Content = panel;
        await dialog.ShowDialog(this);
    }

    private async Task ShutdownAsync()
    {
        _lifetime.Cancel();
        try { await CloseTerminalAsync(); }
        catch { /* Window is already closing. */ }
        _lifetime.Dispose();
    }
}
