using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using ZteImeiStudio.Windows.Esim;

namespace ZteImeiStudio.Windows;
public sealed partial class MainWindow
{
    private EsimSnapshot? _esimSnapshot;
    private bool _esimAuthorized;
    private string? _esimSelected;
    private TextBox? _esimCode, _esimConfirmation, _esimAddress, _esimMatchingId;
    private ComboBox? _esimInputMode;
    private bool _esimManual;
    private int _esimInputGeneration;
    private ListBox? _esimProfiles;
    private Button? _esimRead, _esimDownload, _esimEnable, _esimDelete, _esimQr, _esimInstall, _esimInstallPage;
    private TextBlock? _esimProgress, _esimCardStatus;
    private bool _esimCardChecked, _esimChecking;
    private EsimCardStatus? _esimCard;
    private string? _esimCardTarget;
    private string EsimTarget() => $"{_snapshot?.IpAddress}|{_snapshot?.Serial}|{_snapshot?.ConnectionMode}|{_snapshot?.IsConnected}";
    private string _esimStatus = "Прочитайте профили, чтобы разрешить изменения.";

    private void BuildEsim()
    {
        AddCard("SIM-карта", "Съёмная eUICC в физическом SIM-слоте 1. Проверено с 9eSIM V0 на ZTE MU5250 B31.", panel =>
        {
            panel.Children.Add(Muted("Встроенная eSIM ZTE и обычные SIM-карты не поддерживаются. Загрузка использует интернет компьютера."));
            panel.Children.Add(Muted("Для загрузки профиля оператора нужна съёмная eUICC. Обычная SIM не становится eUICC после сканирования QR. Ошибка чтения не определяет тип карты."));
            _esimCardStatus = Muted(EsimCardLabel()); _esimCardStatus.Name = "EsimCardType"; panel.Children.Add(_esimCardStatus);
            _esimInstall = ActionButton("Установить агент и веб-панель", () => ExecuteAsync(ModemOperation.InstallAgent, (string[]?)null), false);
            _esimInstall.Name = "EsimInstallPermanentAgent"; panel.Children.Add(_esimInstall);
            _esimInstallPage = ActionButton("Установить / обновить страницу eSIM на модеме", InstallEsimLauncherPageAsync, false);
            _esimInstallPage.Name = "EsimInstallLauncherPage"; panel.Children.Add(_esimInstallPage);
            panel.Children.Add(Muted("Обновляет агент и Launcher. Другие страницы и настройки дисплея сохраняются; профили eSIM не меняются."));
            _esimRead = ActionButton("Проверить карту и профили", () => RunEsimUiAsync(new EsimRequest { Operation = "list" }), true);
            _esimRead.Name = "EsimRead";
            var reads = new WrapPanel(); reads.Children.Add(_esimRead);
            // This local journal remains available while the card operation is running.
            var journal = new Button { Name = "EsimJournal", Content = Localization.Translate("Журнал eSIM"), Background = Elevated, Foreground = Foreground, CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(0), Padding = new Thickness(13, 8), Margin = new Thickness(0, 0, 8, 7) };
            journal.Click += async (_, _) => await ShowEsimJournalAsync(); reads.Children.Add(journal); panel.Children.Add(reads);
            if (_esimSnapshot is not null) panel.Children.Add(Muted("EID · " + EsimValidation.Mask(_esimSnapshot.Eid)));
            if (_esimSnapshot is { Profiles.Count: 0 }) panel.Children.Add(Muted("На карте пока нет профилей."));
            _esimProfiles = new ListBox { Name = "EsimProfiles", MinHeight = 88, MaxHeight = 270, Background = Elevated, Foreground = Foreground };
            var profiles = _esimSnapshot?.Profiles ?? [];
            _esimProfiles.ItemsSource = profiles.Select(p => Localization.Translate(p.DisplayName) + " · " + Localization.Translate(p.State == "enabled" ? "Активный" : p.State == "disabled" ? "Отключён" : "Неизвестное состояние") + " · " + EsimValidation.Mask(p.Iccid) + (p.ServiceProvider is { Length: > 0 } ? " · " + EsimValidation.Label(p.ServiceProvider) : "")).ToArray();
            _esimProfiles.SelectedIndex = profiles.ToList().FindIndex(p => p.Iccid == _esimSelected);
            _esimProfiles.SelectionChanged += (_, _) =>
            {
                _esimSelected = _esimProfiles.SelectedIndex >= 0 && _esimProfiles.SelectedIndex < profiles.Count ? profiles[_esimProfiles.SelectedIndex].Iccid : null;
                UpdateEsimAvailability();
            };
            panel.Children.Add(_esimProfiles);
            var actions = new WrapPanel { Orientation = Orientation.Horizontal };
            _esimEnable = ActionButton("Сделать активным", () => RunSelectedEsimAsync(false), true); _esimEnable.Name = "EsimEnable";
            _esimDelete = ActionButton("Удалить профиль", () => RunSelectedEsimAsync(true), false); _esimDelete.Name = "EsimDelete";
            actions.Children.Add(_esimEnable); actions.Children.Add(_esimDelete); panel.Children.Add(actions);
            panel.Children.Add(Muted("При включении профиля модем кратко отключит мобильное радио и перечитает SIM. Мобильное соединение прервётся. Регистрация в сети проверяется отдельно."));
            panel.Children.Add(Muted("Удалить можно только отключённый профиль."));
        });
        AddCard("Добавить профиль", "Профиль устанавливается отключённым. Код и пароль не сохраняются.", panel =>
        {
            _esimCode = new TextBox { Name = "EsimActivationCode", Watermark = "LPA:1$…", PasswordChar = '•', Background = Elevated, Foreground = Foreground, MinHeight = 38 };
            _esimConfirmation = new TextBox { Name = "EsimConfirmationCode", Watermark = Localization.Translate("Код подтверждения оператора (если требуется)"), PasswordChar = '•', Background = Elevated, Foreground = Foreground, MinHeight = 38 };
            Avalonia.Automation.AutomationProperties.SetName(_esimCode, Localization.Translate("Код активации eSIM"));
            Avalonia.Automation.AutomationProperties.SetName(_esimConfirmation, Localization.Translate("Код подтверждения оператора (если требуется)"));
            _esimCode.TextChanged += (_, _) => UpdateEsimAvailability();
            _esimAddress = new TextBox { Name = "EsimSmdpAddress", Watermark = "SM-DP+ Address", Background = Elevated, Foreground = Foreground, MinHeight = 38 };
            _esimMatchingId = new TextBox { Name = "EsimMatchingId", Watermark = "Activation code (Matching ID)", PasswordChar = '•', Background = Elevated, Foreground = Foreground, MinHeight = 38 };
            Avalonia.Automation.AutomationProperties.SetName(_esimAddress, "SM-DP+ Address");
            Avalonia.Automation.AutomationProperties.SetName(_esimMatchingId, "Activation code (Matching ID)");
            _esimInputMode = new ComboBox { Name = "EsimInputMode", ItemsSource = new[] { Localization.Translate("Полный код / QR"), "SM-DP+ + Activation code" }, SelectedIndex = _esimManual ? 1 : 0, HorizontalAlignment = HorizontalAlignment.Stretch };
            _esimInputMode.SelectionChanged += (_, _) => { _esimManual = _esimInputMode.SelectedIndex == 1; ClearEsimSecrets(); UpdateEsimAvailability(); };
            _esimAddress.TextChanged += (_, _) => UpdateEsimAvailability();
            _esimMatchingId.TextChanged += (_, _) => UpdateEsimAvailability();
            panel.Children.Add(_esimInputMode); panel.Children.Add(_esimCode); panel.Children.Add(_esimAddress); panel.Children.Add(_esimMatchingId); panel.Children.Add(_esimConfirmation);
            var actions = new WrapPanel { Orientation = Orientation.Horizontal };
            _esimQr = ActionButton("Выбрать изображение QR", ReadEsimQrAsync, false); _esimQr.Name = "EsimQr";
            _esimDownload = ActionButton("Установить профиль", SubmitEsimDownloadAsync, true); _esimDownload.Name = "EsimDownload";
            actions.Children.Add(_esimQr); actions.Children.Add(_esimDownload); panel.Children.Add(actions);
            _esimProgress = Muted(_esimStatus); _esimProgress.Name = "EsimStatus"; panel.Children.Add(_esimProgress);
        });
        UpdateEsimAvailability();
    }
    private async Task InstallEsimLauncherPageAsync()
    {
        if (_busy) return;
        var draft = new[] { "style", "metrics", "metric_order" }.ToDictionary(key => key, key => _form.GetValueOrDefault(key));
        _esimAuthorized = false;
        _esimStatus = "Прочитайте профили, чтобы разрешить изменения.";
        ClearEsimSecrets();
        try { await ExecuteAsync(ModemOperation.InstallEsimLauncher, (string[]?)null); }
        finally
        {
            // Refreshing the installed device state must not submit or replace the
            // user's unsaved layout selections on the other desktop page.
            foreach (var (key, value) in draft)
                if (value is null) _form.Remove(key); else _form[key] = value;
        }
    }
    private void UpdateEsimAvailability()
    {
        if (_page != 8) return;
        bool connected = _snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH";
        bool available = !_busy && connected && _terminal?.IsConnected != true && !_terminalOpening;
        bool writes = available && _esimAuthorized && _esimSnapshot is not null;
        if (_esimCardStatus is not null) _esimCardStatus.Text = Localization.Translate(EsimCardLabel());
        var selected = _esimSnapshot?.Profiles.SingleOrDefault(p => p.Iccid == _esimSelected);
        if (_esimRead is not null) _esimRead.IsEnabled = available;
        if (_esimInstall is not null) _esimInstall.IsEnabled = available;
        if (_esimInstallPage is not null) _esimInstallPage.IsEnabled = available;
        if (_esimEnable is not null)
        {
            _esimEnable.IsEnabled = writes && selected?.State is "disabled" or "enabled";
            _esimEnable.Content = Localization.Translate(selected?.State == "enabled" ? "Перечитать активную SIM" : "Сделать активным");
        }
        if (_esimDelete is not null) _esimDelete.IsEnabled = writes && selected?.State == "disabled";
        if (_esimDownload is not null) _esimDownload.IsEnabled = writes && EsimValidation.ActivationCodeValid(EsimActivationInput());
        if (_esimQr is not null) { _esimQr.IsEnabled = !_busy; _esimQr.IsVisible = !_esimManual; }
        if (_esimProfiles is not null) _esimProfiles.IsEnabled = !_busy;
        if (_esimCode is not null) { _esimCode.IsEnabled = !_busy; _esimCode.IsVisible = !_esimManual; }
        if (_esimAddress is not null) { _esimAddress.IsEnabled = !_busy; _esimAddress.IsVisible = _esimManual; }
        if (_esimMatchingId is not null) { _esimMatchingId.IsEnabled = !_busy; _esimMatchingId.IsVisible = _esimManual; }
        if (_esimInputMode is not null) _esimInputMode.IsEnabled = !_busy;
        if (_esimConfirmation is not null) _esimConfirmation.IsEnabled = !_busy;
    }
    private string EsimCardLabel() => _esimChecking ? "Карта: проверка…"
        : _esimAuthorized && _esimSnapshot is not null ? "Карта: eUICC подтверждена"
        : _esimCardTarget == EsimTarget() && _esimCard?.Kind == "ordinary_sim" ? "Карта: обычная SIM. Управление eSIM недоступно."
        : _esimCardChecked ? "Карта: тип не определён. Повторите проверку."
        : "Карта ещё не проверена.";
    private string? EsimActivationInput() => _esimManual ? EsimValidation.ComposeManual(_esimAddress?.Text, _esimMatchingId?.Text) : _esimCode?.Text?.Trim();
    private void ClearEsimSecrets()
    {
        _esimInputGeneration++;
        if (_esimCode is not null) _esimCode.Text = "";
        if (_esimConfirmation is not null) _esimConfirmation.Text = "";
        if (_esimAddress is not null) _esimAddress.Text = "";
        if (_esimMatchingId is not null) _esimMatchingId.Text = "";
    }
    private async Task ReadEsimQrAsync()
    {
        int generation = _esimInputGeneration;
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = Localization.Translate("Выбрать изображение QR"), AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("QR image") { Patterns = ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp"] }],
        });
        if (files.Count != 1 || files[0].TryGetLocalPath() is not { } path) return;
        try { var code = await Task.Run(() => EsimQr.Read(path)); if (_page == 8 && !_busy && !_esimManual && generation == _esimInputGeneration && !_lifetime.IsCancellationRequested && _esimCode is not null) _esimCode.Text = code; }
        catch { SetStatus("Изображение должно содержать ровно один действительный QR-код eSIM.", true); }
    }
    private async Task SubmitEsimDownloadAsync()
    {
        if (_busy || !_esimAuthorized || _esimSnapshot is null) return;
        var request = new EsimRequest { Operation = "download", ExpectedSnapshot = _esimSnapshot, ActivationCode = EsimActivationInput(), ConfirmationCode = string.IsNullOrEmpty(_esimConfirmation?.Text) ? null : _esimConfirmation.Text };
        ClearEsimSecrets(); await RunEsimUiAsync(request);
    }
    private async Task RunSelectedEsimAsync(bool delete)
    {
        if (_busy || !_esimAuthorized || _esimSnapshot is null) return;
        var selected = _esimSnapshot.Profiles.SingleOrDefault(p => p.Iccid == _esimSelected);
        if (selected is null || (delete ? selected.State != "disabled" : selected.State is not ("disabled" or "enabled"))) return;
        if (delete && !await ConfirmAsync("Удалить профиль eSIM без возможности отмены?", selected.DisplayName + "\nICCID · " + EsimValidation.Mask(selected.Iccid))) return;
        await RunEsimUiAsync(new EsimRequest { Operation = delete ? "delete" : "enable", ExpectedSnapshot = _esimSnapshot, Iccid = selected.Iccid, ConfirmDelete = delete });
    }
    private async Task RunEsimUiAsync(EsimRequest request)
    {
        if (_busy) return;
        _esimAuthorized = false; _esimCard = null; _esimCardChecked = true; _esimChecking = true;
        ClearEsimSecrets(); SetBusy(true);
        _esimStatus = "Проверка карты…";
        bool inProgress = true, succeeded = false;
        try
        {
            var progress = new Progress<string>(stage => Dispatcher.UIThread.Post(() =>
            {
                if (!inProgress) return;
                _esimStatus = stage switch { "downloading" => "Загрузка профиля…", "enabling" => "Включение профиля…", "radio_offline" => "Временное отключение мобильного радио…", "radio_online" => "Восстановление мобильного радио…", "reading_modem" => "Проверка перечитанной SIM в модеме…", "deleting" => "Удаление профиля…", "notifications" => "Доставка уведомлений оператору…", "verifying" => "Проверка результата…", "reading_profiles" => "Чтение профилей…", "cleanup" => "Закрытие соединения с картой…", _ => "Проверка карты…" };
                if (_esimProgress is not null) _esimProgress.Text = Localization.Translate(_esimStatus);
            }));
            var result = await _service.RunEsimAsync(request, progress, _lifetime.Token);
            if (!result.Ok) throw new EsimException(result.Error, result.ComponentError);
            var card = EsimCardStatus.FromAcceptedResult(result, request.Operation);
            if (result.Snapshot is not null) EsimValidation.Postcondition(request, result.Snapshot);
            if (request.Operation == "enable" && (result.ModemVerified != true || result.RadioRestored != true)) throw new EsimException("postcondition_failed");
            _esimSnapshot = result.Snapshot;
            _esimCard = card; _esimCardTarget = EsimTarget();
            _esimAuthorized = result.Snapshot is not null;
            if (_esimSnapshot is null) _esimSelected = null;
            succeeded = true;
            _esimStatus = card.Kind == "ordinary_sim" ? "Карта: обычная SIM. Управление eSIM недоступно." : request.Operation switch { "download" => "Профиль установлен отключённым. Выберите его для включения.", "enable" => "Профиль активен, модем перечитал SIM и восстановил мобильное радио. Регистрация в сети ещё не проверена.", "delete" => "Профиль удалён с карты.", _ => "Профили прочитаны. Можно выбрать профиль или загрузить новый." };
            if (result.NotificationsPending) _esimStatus += " " + Localization.Translate("Уведомления оператору остались в очереди карты.");
        }
        catch (Exception error)
        {
            _esimAuthorized = false; _esimCard = null; _esimSnapshot = null; _esimSelected = null;
            var code = error is EsimException esim ? esim.Code : "operation_failed";
            _esimStatus = Localization.Translate(EsimDiagnostics.FailureMessage(code)) + " " + Localization.Translate("Код: {code}. Подробности — в журнале eSIM.").Replace("{code}", code, StringComparison.Ordinal);
        }
        finally { inProgress = false; _esimChecking = false; ClearEsimSecrets(); SetBusy(false); SetStatus(_esimStatus, !succeeded); if (_page == 8) RenderPage(); }
    }

    private async Task ShowEsimJournalAsync()
    {
        var dialog = new Window { Title = Localization.Translate("Журнал eSIM"), Width = 940, Height = 580, MinWidth = 600, MinHeight = 300, Background = Surface, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var layout = new DockPanel { Margin = new Thickness(18) };
        var close = new Button { Content = Localization.Translate("Закрыть"), Background = Elevated, Foreground = Foreground, CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(0), Padding = new Thickness(13, 8), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        close.Click += (_, _) => dialog.Close(); DockPanel.SetDock(close, Dock.Bottom); layout.Children.Add(close);
        var note = Muted("Этапы, длительность, счётчики APDU и HTTP, результат. QR, коды, ответы карты и идентификаторы не записываются.");
        DockPanel.SetDock(note, Dock.Top); layout.Children.Add(note);
        var text = new TextBox { Name = "EsimJournalText", IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, FontFamily = new FontFamily("monospace"), FontSize = 12, Foreground = Foreground, Background = Elevated };
        layout.Children.Add(text); dialog.Content = layout;
        bool reading = false, closed = false;
        async Task Refresh()
        {
            if (reading || closed) return;
            reading = true;
            try
            {
                var entries = await _service.GetLogsAsync(_lifetime.Token);
                if (!closed) { text.Text = string.Join("\n", entries.Where(x => x.Message.StartsWith("eSIM[", StringComparison.Ordinal)).Select(x => $"{x.Timestamp.LocalDateTime:HH:mm:ss} {x.Level} {x.Message}")); text.CaretIndex = text.Text.Length; }
            }
            catch { /* The existing journal stays visible while the app closes. */ }
            finally { reading = false; }
        }
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        timer.Tick += async (_, _) => await Refresh();
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        await Refresh(); timer.Start(); await dialog.ShowDialog(this);
    }
}
