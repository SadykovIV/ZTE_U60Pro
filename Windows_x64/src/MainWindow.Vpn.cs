using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.LogicalTree;
using Avalonia.Platform.Storage;
using System.Text;
using ZteImeiStudio.Windows.Features;

namespace ZteImeiStudio.Windows;

public sealed partial class MainWindow
{
    private readonly List<(Button Button, Func<bool> Available)> _vpnActions = [];
    private bool VpnConnected => !_busy && _snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH" && _terminal?.IsConnected != true && !_terminalOpening && SelectedConnectionMatches();
    private bool VpnReady => VpnConnected && _snapshot?.VpnPage?.ComponentsReady == true;
    private Button VpnButton(string title, Func<Task> work, Func<bool> available, bool prominent = false)
    {
        var button = ActionButton(title, work, prominent);
        _vpnActions.Add((button, available)); button.IsEnabled = available();
        return button;
    }
    private void UpdateVpnAvailability()
    {
        if (_page != 4) return;
        foreach (var item in _vpnActions) item.Button.IsEnabled = item.Available();
    }
    private void BuildVpn()
    {
        _vpnActions.Clear();
        var vpn = _snapshot?.VpnPage;
        AddCard("VPN на модеме", "Профили хранятся на модеме. Программа управляет ими по SSH; агент и экран модема используют тот же список.", panel =>
        {
            panel.Children.Add(ValueLine("Состояние", _snapshot?.Vpn));
            panel.Children.Add(VpnButton("Обновить состояние VPN", () => ExecuteAsync(ModemOperation.RefreshVpn, (string[]?)null), () => VpnConnected));
            if (vpn?.ComponentsReady != true)
                panel.Children.Add(VpnButton("Установить / обновить", () => ExecuteAsync(ModemOperation.InstallVpn, (string[]?)null), () => VpnConnected, true));
            panel.Children.Add(Muted("Установка добавляет контроллер и ядро VPN. Агент и страницы экрана устанавливаются отдельно в своих разделах."));
        });
        AddCard("Профили VPN", "Импорт сохраняет профиль без активации. Выбор профиля применяется также в агенте и на экране модема.", panel =>
        {
            panel.Children.Add(Muted(vpn is null ? "Обновите состояние, чтобы прочитать профили с модема." : vpn.Enabled ? "Wi-Fi с VPN включён" : "Wi-Fi с VPN выключен"));
            if (vpn is not null)
            {
                if (vpn.Enabled && vpn.ProfileDetails?.Any(p => p.Active && p.Protocol == "ikev2") == true)
                    panel.Children.Add(Muted(vpn.Ikev2Connected ? "IKEv2 подключён: частные сети доступны через VPN." : vpn.Ikev2State == "waiting" ? "Ожидание подключения IKEv2: подтвердите PUSH в приложении MFA." : "IKEv2 не подключён: частные сети и DNS недоступны. Публичные IPv4 доступны через LTE, если адрес уже известен."));
                panel.Children.Add(VpnButton(vpn.Enabled ? "Выключить Wi-Fi с VPN" : "Включить Wi-Fi с VPN", async () =>
                {
                    if (await ConfirmAsync("Wi-Fi с VPN", vpn.Enabled ? "Выключить Wi-Fi с VPN? Устройства этой сети потеряют подключение." : "Включить Wi-Fi с VPN с выбранным профилем?"))
                        await ExecuteAsync(ModemOperation.SetVpnEnabled, new Dictionary<string,string> { ["vpn_enabled"] = (!vpn.Enabled).ToString().ToLowerInvariant() });
                }, () => VpnReady && (vpn.Enabled || vpn.ProfileDetails?.Any(p => p.Active) == true)));
                if (vpn.ProfileDetails is not { Count: > 0 }) panel.Children.Add(Muted("Профили не добавлены"));
                foreach (var profile in vpn.ProfileDetails ?? [])
                {
                    var row = new StackPanel { Spacing = 8, Margin = new Avalonia.Thickness(0, 8, 0, 8) };
                    row.Children.Add(ValueLine(profile.Name, VpnProtocolLabel(profile.Protocol) + " · " + profile.Transport + (profile.Active ? " · " + Localization.Translate("Активен") : "")));
                    if (profile.UpdateAvailable) row.Children.Add(Muted("Обновление сохранено. Примените его, чтобы переподключиться с новыми настройками."));
                    if (profile.RemovedFromSubscription) row.Children.Add(Muted("Профиль удалён из подписки; активное подключение сохранено."));
                    foreach (var warning in profile.Warnings ?? [])
                        if (Features.VpnMessages.Warnings.TryGetValue(warning, out var message))
                            row.Children.Add(Muted(message));
                    var renameKey = "vpn_rename_" + profile.Id;
                    if (! _form.ContainsKey(renameKey)) _form[renameKey] = profile.Name;
                    row.Children.Add(Field("Название профиля", renameKey, profile.Name));
                    var actions = new WrapPanel { Orientation = Orientation.Horizontal };
                    actions.Children.Add(VpnButton(profile.Protocol == "ikev2" && profile.Active ? "Переподключить IKEv2" : profile.UpdateAvailable ? "Применить обновление" : "Сделать активным", async () =>
                    {
                        if (await ConfirmAsync("Выбрать профиль VPN?", profile.Protocol == "ikev2" ? "Подключить IKEv2? Подтвердите PUSH в приложении MFA после запуска подключения. Если время ожидания истекло, повторите подключение вручную." : "При первой активации будет настроена и включена сеть Wi-Fi с VPN. При смене работающего профиля VPN переподключится."))
                            await ExecuteAsync(ModemOperation.ActivateVpnProfile, new Dictionary<string,string> { ["vpn_profile_id"] = profile.Id });
                    }, () => VpnReady && (profile.Protocol == "ikev2" || !profile.Active || profile.UpdateAvailable)));
                    actions.Children.Add(VpnButton("Переименовать", async () =>
                    {
                        if (await ConfirmAsync("Переименовать профиль VPN?", "Сохранить новое название выбранного профиля VPN?"))
                            await ExecuteAsync(ModemOperation.RenameVpnProfile, new Dictionary<string,string> { ["vpn_profile_id"] = profile.Id, ["vpn_profile_name"] = Get(renameKey) });
                    }, () => VpnReady));
                    if (profile.Protocol == "ikev2")
                        actions.Children.Add(VpnButton("Редактировать IKEv2", () => ExecuteAsync(ModemOperation.LoadVpnIkev2, new Dictionary<string,string> { ["vpn_profile_id"] = profile.Id }), () => VpnReady));
                    actions.Children.Add(VpnButton("Удалить профиль", async () =>
                    {
                        if (await ConfirmAsync("Удалить профиль VPN?", "Для повторного импорта понадобится исходная ссылка или файл профиля."))
                            await ExecuteAsync(ModemOperation.DeleteVpnProfile, new Dictionary<string,string> { ["vpn_profile_id"] = profile.Id });
                    }, () => VpnReady && !profile.Active));
                    row.Children.Add(actions); panel.Children.Add(row);
                }
                panel.Children.Add(Muted("Активный профиль можно удалить после выбора другого профиля."));
            }
        });
        if (vpn?.LastImport is { } summary)
            AddCard("Результат импорта", "", panel =>
            {
                foreach (var item in new[] { ("Добавлено", summary.Added), ("Обновлено", summary.Updated), ("Удалено", summary.Removed), ("Дубликаты", summary.Duplicates), ("Пропущено", summary.Skipped.Count) })
                    panel.Children.Add(ValueLine(item.Item1, item.Item2.ToString()));
                if (summary.RetainedActive > 0) panel.Children.Add(Muted("Текущее подключение сохранено. Обновлённый профиль можно применить отдельно."));
                foreach (var item in summary.Skipped) panel.Children.Add(Muted("#" + item.Index + " · " + item.Code));
            });
        AddCard("Добавить профиль VPN", "Ссылки VLESS и Hysteria2, файлы WireGuard, AmneziaWG 2 и 3.1. Импорт сохраняет профиль; активация выполняется отдельно.", panel =>
        {
            panel.Children.Add(Field("Ссылка или конфигурация VPN", "vpn_secret_uri", "vless://… / hy2://… / [Interface]", secret: true, multiline: true));
            panel.Children.Add(Field("Название профиля (необязательно)", "vpn_import_name", "Название"));
            panel.Children.Add(VpnButton("Открыть файл профиля", ReadVpnProfileFileAsync, () => !_busy));
            panel.Children.Add(VpnButton("Импортировать профиль", async () =>
            {
                var input = Get("vpn_secret_uri");
                var config = DeviceFeatureService.IsVpnConfig(input);
                if (!config) input = DeviceFeatureService.ValidateVpnUri(input);
                await ExecuteAsync(config ? ModemOperation.ImportVpnConfig : ModemOperation.ImportVpnProfile,
                    new Dictionary<string,string> { ["vpn_secret_uri"] = input, ["vpn_profile_name"] = Get("vpn_import_name") });
            }, () => VpnReady, true));
            panel.Children.Add(Muted("Данные профиля не записываются в журнал программы и очищаются после отправки."));
        });
        BuildVpnIkev2();
        AddCard("Подписки VPN", "Программа загружает подписку через интернет компьютера. Все её профили появляются в общем списке на модеме.", panel =>
        {
            panel.Children.Add(Field("HTTPS-ссылка подписки", "vpn_subscription_url", "https://…", secret: true));
            panel.Children.Add(Field("Название подписки (необязательно)", "vpn_subscription_name", "Название"));
            panel.Children.Add(VpnButton("Добавить подписку", () => ExecuteAsync(ModemOperation.ImportVpnSubscription,
                new Dictionary<string,string> { ["vpn_subscription_url"] = Get("vpn_subscription_url"), ["vpn_subscription_name"] = Get("vpn_subscription_name") }), () => VpnReady, true));
            foreach (var subscription in vpn?.Subscriptions ?? [])
            {
                panel.Children.Add(ValueLine(subscription.Name, subscription.Host));
                panel.Children.Add(ValueLine("Профили", subscription.ProfileCount.ToString()));
                var actions = new WrapPanel { Orientation = Orientation.Horizontal };
                actions.Children.Add(VpnButton("Обновить подписку", () => ExecuteAsync(ModemOperation.UpdateVpnSubscription,
                    new Dictionary<string,string> { ["vpn_subscription_id"] = subscription.Id }), () => VpnReady));
                actions.Children.Add(VpnButton("Удалить подписку", () => ExecuteAsync(ModemOperation.DeleteVpnSubscription,
                    new Dictionary<string,string> { ["vpn_subscription_id"] = subscription.Id }), () => VpnReady));
                panel.Children.Add(actions);
            }
            panel.Children.Add(Muted("Удаление подписки сохраняет её профили. Обновление не прерывает текущее VPN-подключение."));
        });
        AddCard("Настройки Wi-Fi с VPN", "Название и пароль можно менять, когда Wi-Fi с VPN выключен.", panel =>
        {
            panel.Children.Add(VpnButton("Прочитать настройки", () => ExecuteAsync(ModemOperation.RefreshVpnWifi, (string[]?)null), () => VpnConnected));
            panel.Children.Add(Field("Название сети (SSID)", "ssid", "ZTE-VPN"));
            var modes = new ComboBox
            {
                ItemsSource = new[] { "Пароль основной сети", "Новый пароль", "Сохранить текущий" }.Select(Localization.Translate).ToArray(),
                SelectedIndex = Get("password_mode") switch { "custom" => 1, "preserve" => 2, _ => 0 },
                MinWidth = 240, HorizontalAlignment = HorizontalAlignment.Left,
            };
            modes.SelectionChanged += (_, _) => _form["password_mode"] = modes.SelectedIndex switch { 1 => "custom", 2 => "preserve", _ => "main" };
            panel.Children.Add(modes);
            panel.Children.Add(Field("Новый пароль", "custom_password", "Пароль", secret: true));
            panel.Children.Add(Field("Повторите пароль", "confirm_password", "Повторите", secret: true));
            panel.Children.Add(VpnButton("Сохранить настройки сети", () => ExecuteAsync(ModemOperation.SaveVpnWifi, ["ssid", "password_mode", "custom_password", "confirm_password"]), () => VpnReady && vpn?.Enabled != true && vpn?.SettingsSupported == true));
        });
    }
    private static string VpnProtocolLabel(string protocol) => protocol switch
    { "vless" => "VLESS", "hysteria2" => "HY2", "ikev2" => "IKEv2", "wireguard" => "WireGuard", "amneziawg2" => "AWG 2", "amneziawg3" => "AWG 3", "amneziawg3.1" => "AWG 3.1", _ => protocol };

    private void BuildVpnIkev2()
    {
        if (!_form.ContainsKey("vpn_ikev2_name")) _form["vpn_ikev2_name"] = "UserGate";
        if (!_form.ContainsKey("vpn_ikev2_dns")) _form["vpn_ikev2_dns"] = "10.0.2.1";
        var editing = Get("vpn_ikev2_id").Length > 0;
        AddCard(editing ? "Редактировать IKEv2" : "Добавить профиль IKEv2", "В отдельной сети VPN Wi-Fi: частные сети 10/8, 172.16/12 и 192.168/16 — через VPN; публичные IPv4 — через LTE. DNS направляется через VPN. Основная Wi-Fi сеть сохраняет свои настройки.", panel =>
        {
            panel.Children.Add(Field("Название профиля", "vpn_ikev2_name", "UserGate"));
            panel.Children.Add(Field("Адрес сервера IKEv2", "vpn_ikev2_server", "vpn.example.com"));
            panel.Children.Add(Field("Имя сервера в сертификате (по умолчанию адрес сервера)", "vpn_ikev2_server_id", "vpn.example.com"));
            panel.Children.Add(Field("Логин IKEv2", "vpn_ikev2_username", "Логин"));
            panel.Children.Add(Field(editing ? "Новый пароль IKEv2 (пусто — сохранить прежний)" : "Пароль IKEv2", "vpn_ikev2_password", "Пароль", secret: true));
            panel.Children.Add(Field("DNS через VPN", "vpn_ikev2_dns", "10.0.2.1"));
            panel.Children.Add(Field("Сертификат центра сертификации (CA), PEM", "vpn_ikev2_ca", "-----BEGIN CERTIFICATE-----", multiline: true));
            panel.Children.Add(VpnButton("Открыть сертификат PEM", ReadVpnIkev2CertificateAsync, () => !_busy));
            if (editing) panel.Children.Add(VpnButton("Новый профиль IKEv2", () =>
            {
                foreach (var key in _form.Keys.Where(key => key.StartsWith("vpn_ikev2_", StringComparison.Ordinal)).ToArray()) _form.Remove(key);
                ClearSecrets(); RenderPage(); return Task.CompletedTask;
            }, () => !_busy));
            panel.Children.Add(VpnButton("Сохранить IKEv2", () => ExecuteAsync(ModemOperation.SaveVpnIkev2,
                new[] { "vpn_ikev2_id", "vpn_ikev2_name", "vpn_ikev2_server", "vpn_ikev2_server_id", "vpn_ikev2_username", "vpn_ikev2_password", "vpn_ikev2_ca", "vpn_ikev2_dns" }), () => VpnReady, true));
            panel.Children.Add(Muted("Сохранение не переключает подключение. Выберите профиль и нажмите «Сделать активным». Пароль передаётся по SSH и не возвращается при чтении настроек."));
            panel.Children.Add(Muted("После запуска подключения подтвердите PUSH в приложении MFA. Если время ожидания истекло, нажмите «Переподключить IKEv2»."));
        });
    }

    private async Task ReadVpnIkev2CertificateAsync()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { Title = Localization.Translate("Открыть сертификат PEM"), AllowMultiple = false });
        if (files.Count != 1) return;
        try
        {
            await using var stream = await files[0].OpenReadAsync();
            var bytes = new byte[65537]; var size = 0;
            while (size < bytes.Length)
            {
                var read = await stream.ReadAsync(bytes.AsMemory(size), _lifetime.Token);
                if (read == 0) break;
                size += read;
            }
            if (size > 65536) throw new InvalidDataException();
            _form["vpn_ikev2_ca"] = new UTF8Encoding(false, true).GetString(bytes, 0, size).TrimStart('\uFEFF');
            // Updating the visible certificate field does not rebuild or clear the password field.
            var input = _body.GetLogicalDescendants().OfType<TextBox>().FirstOrDefault(box => box.Tag as string == "vpn_ikev2_ca");
            if (input is not null) input.Text = _form["vpn_ikev2_ca"];
        }
        catch (OperationCanceledException) { throw; }
        catch { SetStatus(VpnMessages.Errors["VPN_IKEV2_INVALID_CERTIFICATE"], true); }
    }
    private async Task ReadVpnProfileFileAsync()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { Title = Localization.Translate("Открыть файл профиля"), AllowMultiple = false });
        if (files.Count != 1) return;
        try
        {
            await using var stream = await files[0].OpenReadAsync();
            var bytes = new byte[32769]; var size = 0;
            while (size < bytes.Length)
            {
                var read = await stream.ReadAsync(bytes.AsMemory(size), _lifetime.Token);
                if (read == 0) break; size += read;
            }
            if (size > 32768) throw new InvalidDataException();
            var uri = new UTF8Encoding(false, true).GetString(bytes, 0, size).TrimStart('\uFEFF');
            if (!DeviceFeatureService.IsVpnConfig(uri)) uri = DeviceFeatureService.ValidateVpnUri(uri);
            _secretFields["vpn_secret_uri"].Text = uri;
        }
        catch (OperationCanceledException) { throw; }
        catch { SetStatus("Нужен файл UTF-8 со ссылкой VLESS/Hysteria2 или конфигурацией WireGuard/AmneziaWG, не больше 32 КиБ.", true); }
    }
}
