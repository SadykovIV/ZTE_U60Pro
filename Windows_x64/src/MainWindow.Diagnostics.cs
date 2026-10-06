using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace ZteImeiStudio.Windows;

public sealed partial class MainWindow
{
    private Button? _researchCollectButton;
    private Button? _firmwareAdaptationButton;
    private Button? _diagnosticAccessButton;
    private Button? _refreshAdbButton;
    private Button? _verifyBackupKeyButton;
    private TextBlock? _backupKeyCheckStatus;
    private string _backupKeyCheckResult = "";
    private string _backupKeyCheckHost = "";
    private CheckBox? _adbEnabledCheckbox;
    private bool _updatingAdbCheckbox;
    private TextBlock? _diagnosticConnectionStatus;
    private TextBlock? _diagnosticAccessStatus;
    private string _diagnosticConnectionResult = "";
    private string _diagnosticConnectionInput = "";
    private string _diagnosticAccessResult = "";
    private string _diagnosticAccessIdentity = "";
    private string DiagnosticInputKey() => string.Join('\n', new[] { "host", "key_path", "known_hosts_path" }.Select(Get));
    private string ConnectedDiagnosticKey() => string.Join('\n', _snapshot?.Serial, _snapshot?.IpAddress, _snapshot?.ConnectionMode);

    private void BuildConnectionMethods(StackPanel panel)
    {
        var methods = new StackPanel { Spacing = 10 };
        methods.Children.Add(Muted(Localization.IsEnglish
            ? "Application operations use SSH. Web pages open in your browser; USB ADB is only for preparing SSH."
            : "Операции программы выполняются по SSH. Веб-страницы открываются в браузере; USB ADB нужен только для подготовки SSH."));
        var links = new WrapPanel();
        var web = ActionButton(Localization.IsEnglish ? "Open modem web page" : "Открыть веб-интерфейс модема", () => OpenConnectionBrowserAsync(false), false);
        web.Name = "OpenModemWeb"; links.Children.Add(web);
        var agent = ActionButton(Localization.IsEnglish ? "Open agent web page" : "Открыть веб-панель агента", () => OpenConnectionBrowserAsync(true), false);
        agent.Name = "OpenAgentWeb"; links.Children.Add(agent); methods.Children.Add(links);
        var discover = ActionButton("Проверить подключения", () => ExecuteAsync(ModemOperation.DiscoverConnections,
            ["host", "key_path", "known_hosts_path"]), false);
        discover.Name = "DiscoverConnections"; methods.Children.Add(discover);
        _diagnosticConnectionStatus = Muted(_diagnosticConnectionInput == DiagnosticInputKey() ? _diagnosticConnectionResult : "Состояние не проверено");
        methods.Children.Add(_diagnosticConnectionStatus);
        _diagnosticAccessButton = ActionButton("Проверить доступы", () => ExecuteAsync(ModemOperation.RefreshAccess, (string[]?)null), false);
        _diagnosticAccessButton.Name = "DiagnosticAccess"; methods.Children.Add(_diagnosticAccessButton);
        _diagnosticAccessStatus = Muted(_diagnosticAccessIdentity == ConnectedDiagnosticKey() ? _diagnosticAccessResult : "Состояние не проверено");
        methods.Children.Add(_diagnosticAccessStatus);
        _refreshAdbButton = ActionButton(Localization.IsEnglish ? "Check ADB state" : "Проверить состояние ADB",
            () => ExecuteAsync(ModemOperation.RefreshAdbState, (string[]?)null), false);
        _refreshAdbButton.Name = "RefreshAdbState"; methods.Children.Add(_refreshAdbButton);
        _adbEnabledCheckbox = new AdbIntentCheckBox { Name = "AdbEnabled", IsThreeState = true,
            Content = Localization.IsEnglish ? "Enable ADB" : "Включить ADB", IsChecked = _snapshot?.AdbEnabled };
        _adbEnabledCheckbox.IsCheckedChanged += async (_, _) =>
        {
            if (_updatingAdbCheckbox) return;
            var requested = _adbEnabledCheckbox.IsChecked;
            var ssh = _snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH";
            if (_busy || _terminal?.IsConnected == true || _terminalOpening || _snapshot?.PreparationPending == true)
            { UpdateDiagnosticAvailability(); return; }
            if (!ssh)
            {
                // An unknown state is an ON request only, never authority to send OFF.
                if (requested != true || !CanBootstrapAdb()) { UpdateDiagnosticAvailability(); return; }
                await ExecuteAsync(ModemOperation.EnableDiagnosticAdb, ["host", "web_password", "backup_key_suffix", "skip_firmware_check"]);
                return;
            }
            if (_snapshot?.AdbControlSupported != true || _snapshot.AdbEnabled is null || _snapshot.AdbActivationPending || requested is null || requested == _snapshot.AdbEnabled)
            { UpdateDiagnosticAvailability(); return; }
            await ExecuteAsync(ModemOperation.SetAdbEnabled, new Dictionary<string,string> { ["enabled"] = requested.Value ? "true" : "false" });
        };
        var adbControls = new WrapPanel();
        adbControls.Children.Add(_adbEnabledCheckbox); adbControls.Children.Add(OperationInfoButton(OperationHelpContent.DiagnosticAdb));
        methods.Children.Add(adbControls);
        methods.Children.Add(Muted(_snapshot?.AdbActivationPending == true
            ? (Localization.IsEnglish ? "The ADB operation is unfinished. Connect over SSH and check its state, or select the checkbox to resume preparation." : "Операция ADB не завершена. Подключитесь по SSH и проверьте состояние либо подтвердите продолжение подготовки флажком.")
            : _snapshot?.AdbStatus ?? (Localization.IsEnglish ? "ADB state is unknown. To enable it initially, complete the SSH preparation settings and select the checkbox." : "Состояние ADB неизвестно. Для первоначального включения заполните настройки подготовки SSH и установите флажок.")));
        var setup = new StackPanel { Spacing = 8 };
        setup.Children.Add(Muted(Localization.IsEnglish
            ? "These credentials are only for preparing SSH. With working root USB ADB, the Web password can be left empty."
            : "Эти пароли используются только для подготовки SSH. При работающем root USB ADB пароль Web можно оставить пустым."));
        setup.Children.Add(FieldPair(Field("Пароль веб-интерфейса", "web_password", "Введите пароль", secret: true), Field("Пароль агента / SSH", "agent_password", "Введите пароль", secret: true)));
        setup.Children.Add(Field("Backup-key suffix (необязательный)", "backup_key_suffix", "Пусто — известный ключ формата", secret: true));
        _verifyBackupKeyButton = ActionButton("Проверить ключ бэкапа", () => ExecuteAsync(ModemOperation.VerifyBackupKey,
            ["host","web_password","backup_key_suffix"]),false);
        _verifyBackupKeyButton.Name = "VerifyBackupKey"; setup.Children.Add(_verifyBackupKeyButton);
        setup.Children.Add(Muted("Только свежий бэкап и проверка расшифровки/формата. ADB, SSH и настройки модема не изменяются."));
        _backupKeyCheckStatus = Muted(_backupKeyCheckHost==Get("host") && _backupKeyCheckResult.Length>0 ? _backupKeyCheckResult : "Ключ бэкапа ещё не проверен.");
        _backupKeyCheckStatus.Name = "BackupKeyCheckStatus";setup.Children.Add(_backupKeyCheckStatus);
        methods.Children.Add(new Expander { Header = Localization.IsEnglish ? "Prepare SSH access" : "Подготовка доступа SSH", Content = setup, HorizontalAlignment = HorizontalAlignment.Stretch });
        panel.Children.Add(new Expander { Name = "ConnectionMethods", Header = Localization.IsEnglish ? "Available connection methods" : "Доступные способы подключения", Content = methods, HorizontalAlignment = HorizontalAlignment.Stretch });
        UpdateDiagnosticAvailability();
    }

    internal static Uri ConnectionBrowserUri(string host, bool agent)
    {
        if (!System.Net.IPAddress.TryParse(host, out var address) || address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
            throw new ArgumentException("Введите IPv4-адрес модема.");
        return new Uri("http://" + address + (agent ? ":8080" : "") + "/");
    }

    private Task OpenConnectionBrowserAsync(bool agent)
    {
        Uri url;
        try { url = ConnectionBrowserUri(Get("host"), agent); }
        catch (ArgumentException) { SetStatus("Введите IPv4-адрес модема.", true); return Task.CompletedTask; }
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true }); }
        catch { SetStatus(Localization.IsEnglish ? "Could not open the web browser." : "Не удалось открыть браузер.", true); }
        return Task.CompletedTask;
    }

    private void BuildDiagnostics()
    {
        BuildFirmwareResearch();
        AddCard("Данные для адаптации прошивки", "Свежее исследование функций программы, текущие файлы экрана и доступные шрифты в одном ZIP.", panel =>
        {
            var row = new WrapPanel();
            _firmwareAdaptationButton = ActionButton("Собрать данные для адаптации прошивки", CollectFirmwareAdaptationAsync, false);
            _firmwareAdaptationButton.Name = "CollectFirmwareAdaptation";
            row.Children.Add(_firmwareAdaptationButton);
            row.Children.Add(OperationInfoButton(OperationHelpContent.FirmwareAdaptation));
            panel.Children.Add(row);
            panel.Children.Add(Muted("Только чтение по текущему SSH. Архив сохраняется в выбранное место; неполный сбор отмечается отдельно."));
        });
        AddCard("Сбор и экспорт", "Сохранённое исследование и действия программы в одном архиве.", panel =>
        {
            panel.Children.Add(Actions(("Сохранить диагностический ZIP", ModemOperation.ExportDiagnostics, null)));
            panel.Children.Add(Muted("Диагностический ZIP включает сохранённое исследование устройства и действия программы. Новое исследование запускается отдельно."));

        });
        UpdateDiagnosticAvailability();
    }

    private void UpdateDiagnosticAvailability()
    {
        var idle = !_busy && _terminal?.IsConnected != true && !_terminalOpening;
        var ssh = _snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH";
        var noPending = _snapshot?.PreparationPending != true && _snapshot?.AdbActivationPending != true;
        if (_verifyBackupKeyButton is not null) _verifyBackupKeyButton.IsEnabled = idle &&
            System.Net.IPAddress.TryParse(Get("host"),out var keyCheckHost) && keyCheckHost.AddressFamily==System.Net.Sockets.AddressFamily.InterNetwork &&
            Get("web_password").Length>0 && !Get("web_password").Contains('\0');
        if (_researchCollectButton is not null) _researchCollectButton.IsEnabled = idle;
        if (_firmwareAdaptationButton is not null) _firmwareAdaptationButton.IsEnabled = idle && ssh;
        if (_diagnosticAccessButton is not null) _diagnosticAccessButton.IsEnabled = idle && ssh;
        if (_refreshAdbButton is not null) _refreshAdbButton.IsEnabled = idle && ssh;
        if (_adbEnabledCheckbox is not null)
        {
            _updatingAdbCheckbox = true;
            _adbEnabledCheckbox.IsThreeState = !ssh || _snapshot?.AdbEnabled is null;
            _adbEnabledCheckbox.IsChecked = ssh ? _snapshot?.AdbEnabled : null;
            _adbEnabledCheckbox.IsEnabled = idle && (ssh
                ? noPending && _snapshot?.AdbControlSupported == true && _snapshot.AdbEnabled is not null
                : CanBootstrapAdb());
            _updatingAdbCheckbox = false;
        }
    }

    private bool CanBootstrapAdb()
    {
        if (_snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH" || _snapshot?.PreparationPending == true) return false;
        if (!System.Net.IPAddress.TryParse(Get("host"), out var host) || host.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) return false;
        var password = Get("web_password");
        return !password.Contains('\0') && (_snapshot?.AdbActivationPending == true || password.Length > 0);
    }

    private sealed class AdbIntentCheckBox : CheckBox
    {
        protected override Type StyleKeyOverride => typeof(CheckBox);
        protected override void Toggle()
        {
            // The first explicit click on unknown requests ON, rather than cycling to OFF.
            if (IsChecked is null) IsChecked = true;
            else base.Toggle();
        }
    }

    private void UpdateDiagnosticConnectionStatus()
    {
        if (_diagnosticConnectionStatus is not null)
            _diagnosticConnectionStatus.Text = Localization.Translate(_diagnosticConnectionInput == DiagnosticInputKey()
                ? _diagnosticConnectionResult : "Состояние не проверено");
    }

    private void InvalidateBackupKeyCheck()
    {
        _backupKeyCheckResult="";_backupKeyCheckHost="";
        if(_backupKeyCheckStatus is not null) _backupKeyCheckStatus.Text=Localization.Translate("Ключ бэкапа ещё не проверен.");
    }

    private void RecordDiagnosticResult(ModemOperation operation, OperationResult result, IReadOnlyDictionary<string, string>? parameters)
    {
        if (operation == ModemOperation.VerifyBackupKey)
        {
            _backupKeyCheckHost=parameters?.GetValueOrDefault("host") ?? "";
            _backupKeyCheckResult=Localization.Translate(result.Message);
            if(result.Success && result.Values is { } values)
                _backupKeyCheckResult+="\n"+values.GetValueOrDefault("backup_firmware")+" / "+values.GetValueOrDefault("backup_inner")+
                    "\n"+Localization.Translate("Записей в архиве:")+" "+values.GetValueOrDefault("backup_entries")+"; SHA-256: "+values.GetValueOrDefault("backup_sha256");
            if(_backupKeyCheckStatus is not null) _backupKeyCheckStatus.Text=_backupKeyCheckHost==Get("host") ? _backupKeyCheckResult : Localization.Translate("Ключ бэкапа ещё не проверен.");
        }
        else if (operation == ModemOperation.DiscoverConnections)
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
