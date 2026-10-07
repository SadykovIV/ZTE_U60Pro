using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Platform.Storage;
using System.Text;
using ZteImeiStudio.Windows.Features;

namespace ZteImeiStudio.Windows;

public sealed partial class MainWindow
{
    private readonly List<(Button Button, Func<bool> Available)> _vpnActions = [];
    private bool VpnConnected => !_busy && _snapshot?.IsConnected == true && _snapshot.ConnectionMode == "SSH" && _terminal?.IsConnected != true;
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
                panel.Children.Add(VpnButton(vpn.Enabled ? "Выключить Wi-Fi с VPN" : "Включить Wi-Fi с VPN", async () =>
                {
                    if (await ConfirmAsync("Wi-Fi с VPN", vpn.Enabled ? "Выключить Wi-Fi с VPN? Устройства этой сети потеряют подключение." : "Включить Wi-Fi с VPN с выбранным профилем?"))
                        await ExecuteAsync(ModemOperation.SetVpnEnabled, new Dictionary<string,string> { ["vpn_enabled"] = (!vpn.Enabled).ToString().ToLowerInvariant() });
                }, () => VpnReady && (vpn.Enabled || vpn.ProfileDetails?.Any(p => p.Active) == true)));
                if (vpn.ProfileDetails is not { Count: > 0 }) panel.Children.Add(Muted("Профили не добавлены"));
                foreach (var profile in vpn.ProfileDetails ?? [])
                {
                    var row = new StackPanel { Spacing = 8, Margin = new Avalonia.Thickness(0, 8, 0, 8) };
                    row.Children.Add(ValueLine(profile.Name, profile.Transport + (profile.Active ? " · " + Localization.Translate("Активен") : "")));
                    var renameKey = "vpn_rename_" + profile.Id;
                    if (! _form.ContainsKey(renameKey)) _form[renameKey] = profile.Name;
                    row.Children.Add(Field("Название профиля", renameKey, profile.Name));
                    var actions = new WrapPanel { Orientation = Orientation.Horizontal };
                    actions.Children.Add(VpnButton("Сделать активным", async () =>
                    {
                        if (await ConfirmAsync("Выбрать профиль VPN?", "При первой активации будет настроена и включена сеть Wi-Fi с VPN. При смене работающего профиля VPN переподключится."))
                            await ExecuteAsync(ModemOperation.ActivateVpnProfile, new Dictionary<string,string> { ["vpn_profile_id"] = profile.Id });
                    }, () => VpnReady && !profile.Active));
                    actions.Children.Add(VpnButton("Переименовать", async () =>
                    {
                        if (await ConfirmAsync("Переименовать профиль VPN?", "Сохранить новое название выбранного профиля VPN?"))
                            await ExecuteAsync(ModemOperation.RenameVpnProfile, new Dictionary<string,string> { ["vpn_profile_id"] = profile.Id, ["vpn_profile_name"] = Get(renameKey) });
                    }, () => VpnReady));
                    actions.Children.Add(VpnButton("Удалить профиль", async () =>
                    {
                        if (await ConfirmAsync("Удалить профиль VPN?", "Для повторного импорта понадобится исходная ссылка."))
                            await ExecuteAsync(ModemOperation.DeleteVpnProfile, new Dictionary<string,string> { ["vpn_profile_id"] = profile.Id });
                    }, () => VpnReady && !profile.Active));
                    row.Children.Add(actions); panel.Children.Add(row);
                }
                panel.Children.Add(Muted("Активный профиль можно удалить после выбора другого профиля."));
            }
        });
        AddCard("Добавить профиль VPN", "Поддерживается одна ссылка VLESS: TCP, WebSocket, gRPC или XHTTP. Можно вставить ссылку или открыть текстовый файл с ней.", panel =>
        {
            panel.Children.Add(Field("Ссылка VLESS", "vpn_secret_uri", "vless://…", secret: true));
            panel.Children.Add(Field("Название профиля (необязательно)", "vpn_import_name", "Название"));
            panel.Children.Add(VpnButton("Открыть файл со ссылкой", ReadVpnProfileFileAsync, () => !_busy));
            panel.Children.Add(VpnButton("Импортировать профиль", async () =>
            {
                var uri = DeviceFeatureService.ValidateVpnUri(Get("vpn_secret_uri"));
                await ExecuteAsync(ModemOperation.ImportVpnProfile, new Dictionary<string,string> { ["vpn_secret_uri"] = uri, ["vpn_profile_name"] = Get("vpn_import_name") });
            }, () => VpnReady, true));
            panel.Children.Add(Muted("Ссылка не записывается в журнал программы и очищается после отправки."));
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
    private async Task ReadVpnProfileFileAsync()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { Title = Localization.Translate("Открыть файл со ссылкой"), AllowMultiple = false });
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
            var uri = DeviceFeatureService.ValidateVpnUri(new UTF8Encoding(false, true).GetString(bytes, 0, size).TrimStart('\uFEFF'));
            _secretFields["vpn_secret_uri"].Text = uri;
        }
        catch (OperationCanceledException) { throw; }
        catch { SetStatus("Нужен текстовый файл UTF-8 с одной ссылкой VLESS, не больше 32 КиБ.", true); }
    }
}
