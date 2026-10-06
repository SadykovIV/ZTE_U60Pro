using Avalonia.Platform.Storage;

namespace ZteImeiStudio.Windows;

public sealed partial class MainWindow
{
    private async Task CollectFirmwareAdaptationAsync()
    {
        if (_busy || _terminal?.IsConnected == true || _terminalOpening ||
            _snapshot?.IsConnected != true || _snapshot.ConnectionMode != "SSH") return;
        var selected = new Dictionary<string,string> {
            ["host"] = Get("host"), ["key_path"] = Get("key_path"),
            ["known_hosts_path"] = Get("known_hosts_path"),
        };
        var selectedPort = _service.GetConnectionSettings().Port;
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions {
            Title = Localization.Translate("Сохранить данные для адаптации прошивки"),
            SuggestedFileName = "ZTE-firmware-adaptation-" + DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss") + ".zip",
            DefaultExtension = "zip", FileTypeChoices = [new FilePickerFileType("ZIP") { Patterns = ["*.zip"] }],
            ShowOverwritePrompt = false,
        });
        if (file?.TryGetLocalPath() is not { } path || _busy || _terminal?.IsConnected == true || _terminalOpening) return;
        if (selected.Any(item => Get(item.Key) != item.Value) || _service.GetConnectionSettings().Port != selectedPort)
        { SetStatus("Настройки подключения изменились; начните сбор заново.", true); return; }
        selected["destination"] = path;
        selected["port"] = selectedPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
        await ExecuteAsync(ModemOperation.CollectFirmwareAdaptation, selected);
    }
}
