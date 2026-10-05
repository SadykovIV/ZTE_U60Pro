using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace ZteImeiStudio.Windows;

public sealed partial class MainWindow
{
    private static readonly string[] DiagnosticGroups =
        ["Подключение и ADB", "Устройство и прошивка", "Сбор и экспорт"];
    private int _diagnosticGroup;
    private Button? _researchCollectButton;
    private Button? _diagnosticAccessButton;
    private TextBlock? _diagnosticConnectionStatus;
    private TextBlock? _diagnosticAccessStatus;
    private string _diagnosticConnectionResult = "";
    private string _diagnosticConnectionInput = "";
    private string _diagnosticAccessResult = "";
    private string _diagnosticAccessIdentity = "";
    private string DiagnosticInputKey() => string.Join('\n', new[] { "host", "key_path", "known_hosts_path" }.Select(Get));
    private string ConnectedDiagnosticKey() => string.Join('\n', _snapshot?.Serial, _snapshot?.IpAddress, _snapshot?.ConnectionMode);

    private ComboBox ConnectionModePicker()
    {
        var mode = new ComboBox
        {
            Name = "ConnectionMode", ItemsSource = new[] { "Автоматически", "SSH", "ADB" }.Select(Localization.Translate).ToArray(),
            SelectedIndex = Get("mode") switch { "SSH" => 1, "ADB" => 2, _ => 0 }, MinWidth = 220,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        mode.SelectionChanged += (_, _) => _form["mode"] = mode.SelectedIndex switch { 1 => "SSH", 2 => "ADB", _ => "Автоматически" };
        return mode;
    }

    private void BuildDiagnostics()
    {
        var groups = new WrapPanel { Orientation = Orientation.Horizontal };
        for (var index = 0; index < DiagnosticGroups.Length; index++)
        {
            var group = index;
            var button = ActionButton(DiagnosticGroups[index], async () =>
            {
                _diagnosticGroup = group;
                RenderPage();
                await LoadPageDataAsync();
            }, index == _diagnosticGroup);
            button.Name = "DiagnosticsGroup" + index;
            groups.Children.Add(button);
        }
        _body.Children.Add(groups);
        switch (_diagnosticGroup)
        {
            case 0:
                BuildDiagnosticContext(includePasswords: true);
                AddCard("Подключение и ADB", "Проверка доступных каналов и отдельное включение диагностического ADB.", panel =>
                {
                    var discover = ActionButton("Проверить подключения", () => ExecuteAsync(ModemOperation.DiscoverConnections,
                        ["host", "web_password", "agent_password", "key_path", "known_hosts_path"]), false);
                    discover.Name = "DiscoverConnections";
                    panel.Children.Add(discover);
                    _diagnosticConnectionStatus = Muted(_diagnosticConnectionInput == DiagnosticInputKey() ? _diagnosticConnectionResult : "Состояние не проверено");
                    panel.Children.Add(_diagnosticConnectionStatus);
                    var adb = new WrapPanel();
                    _diagnosticAdbButton = ActionButton(_snapshot?.AdbActivationPending == true ? "Продолжить включение ADB" : "Принудительно включить ADB", () =>
                        ExecuteAsync(ModemOperation.EnableDiagnosticAdb, ["host", "web_password", "backup_key_suffix", "skip_firmware_check"]), false);
                    _diagnosticAdbButton.Name = "EnableDiagnosticAdb";
                    _diagnosticAdbButton.IsEnabled = !_busy && _terminal?.IsConnected != true && !_terminalOpening && _snapshot?.PreparationPending != true;
                    adb.Children.Add(_diagnosticAdbButton);
                    adb.Children.Add(OperationInfoButton(OperationHelpContent.DiagnosticAdb));
                    panel.Children.Add(adb);
                    panel.Children.Add(Muted("Для диагностического ADB нужны USB-кабель и пароль Web выше. Пароль агента не нужен. Доступ можно включить при работающем SSH; возможна перезагрузка модема."));
                    if (_terminal?.IsConnected == true || _terminalOpening) panel.Children.Add(Muted("Перед включением ADB отключите интерактивный терминал."));
                    _diagnosticAccessButton = ActionButton("Проверить доступы", () => ExecuteAsync(ModemOperation.RefreshAccess, (string[]?)null), false);
                    _diagnosticAccessButton.Name = "DiagnosticAccess";
                    panel.Children.Add(_diagnosticAccessButton);
                    panel.Children.Add(Muted("Проверка служб и утилит использует уже подключённый SSH-модем."));
                    panel.Children.Add(ValueLine("Подключение", _snapshot?.IpAddress ?? _snapshot?.Status));
                    _diagnosticAccessStatus = Muted(_diagnosticAccessIdentity == ConnectedDiagnosticKey() ? _diagnosticAccessResult : "Состояние не проверено");
                    panel.Children.Add(_diagnosticAccessStatus);
                    UpdateDiagnosticAvailability();
                });
                break;
            case 1:
                BuildDiagnosticContext(includePasswords: false);
                BuildFirmwareResearch();
                break;
            case 2:
                AddCard("Сбор и экспорт", "Экспорт сохранённых сведений об устройстве и действий программы. Новое исследование запускается отдельно.", panel =>
                {
                    panel.Children.Add(Actions(("Сохранить диагностический ZIP", ModemOperation.ExportDiagnostics, null)));
                    panel.Children.Add(Muted("Диагностический отчёт включает действия программы; исследование устройства экспортируется отдельно."));
                    if (_researchReport is not null) panel.Children.Add(ActionButton("Экспортировать ZIP", ExportFirmwareResearchAsync, false));
                    panel.Children.Add(ActionButton("Перезагрузить модем", async () =>
                    {
                        if (await ConfirmAsync("Перезагрузить модем?", "Соединение будет временно потеряно."))
                            await ExecuteAsync(ModemOperation.RebootDevice, (string[]?)null);
                    }, false));
                });
                break;

        }
    }

    private void BuildDiagnosticContext(bool includePasswords)
    {
        AddCard("Контекст диагностики", "Параметры выбранного устройства для диагностических действий.", panel =>
        {
            panel.Children.Add(Field("Адрес модема", "host", "192.168.0.1"));
            panel.Children.Add(ConnectionModePicker());
            panel.Children.Add(FileField("Приватный ключ SSH", "key_path", "Использовать локальный ключ"));
            panel.Children.Add(FileField("Файл known_hosts", "known_hosts_path", "Использовать локальный known_hosts"));
            if (includePasswords)
            {
                panel.Children.Add(FieldPair(Field("Пароль веб-интерфейса", "web_password", "Введите пароль", secret: true),
                    Field("Пароль агента / SSH", "agent_password", "Введите пароль", secret: true)));
                panel.Children.Add(Field("Backup-key suffix вашей прошивки", "backup_key_suffix", "Только для проверки бэкапа B31", secret: true));
                var skip = new CheckBox { Content = Localization.Translate("Пропустить проверку прошивки"), IsChecked = Get("skip_firmware_check") == "true", Foreground = Warn };
                skip.IsCheckedChanged += (_, _) => _form["skip_firmware_check"] = skip.IsChecked == true ? "true" : "false";
                panel.Children.Add(skip);
            }
        });
    }

    private void UpdateDiagnosticAvailability()
    {
        if (_researchCollectButton is not null) _researchCollectButton.IsEnabled = !_busy && _terminal?.IsConnected != true && !_terminalOpening;
        if (_diagnosticAccessButton is not null) _diagnosticAccessButton.IsEnabled = !_busy && _snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH" && _terminal?.IsConnected != true && !_terminalOpening;
    }

    private void UpdateDiagnosticConnectionStatus()
    {
        if (_diagnosticConnectionStatus is not null)
            _diagnosticConnectionStatus.Text = Localization.Translate(_diagnosticConnectionInput == DiagnosticInputKey()
                ? _diagnosticConnectionResult : "Состояние не проверено");
    }

    private void RecordDiagnosticResult(ModemOperation operation, OperationResult result, IReadOnlyDictionary<string, string>? parameters)
    {
        if (operation == ModemOperation.DiscoverConnections)
        {
            _diagnosticConnectionInput = string.Join('\n', new[] { "host", "key_path", "known_hosts_path" }.Select(key => parameters?.GetValueOrDefault(key) ?? ""));
            _diagnosticConnectionResult = result.Message;
            UpdateDiagnosticConnectionStatus();
        }
        else if (operation == ModemOperation.RefreshAccess)
        {
            _diagnosticAccessIdentity = ConnectedDiagnosticKey();
            _diagnosticAccessResult = result.Message;
            if (_diagnosticAccessStatus is not null) _diagnosticAccessStatus.Text = Localization.Translate(result.Message);
        }
    }
}
