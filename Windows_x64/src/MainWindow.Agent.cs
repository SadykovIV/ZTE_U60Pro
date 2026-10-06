using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Platform.Storage;
using ZteImeiStudio.Windows.Core;

namespace ZteImeiStudio.Windows;

public sealed partial class MainWindow
{
    private AgentCandidate? _customAgent;
    private string? _customAgentContext;
    private Button? _chooseCustomAgentButton, _installCustomAgentButton;
    private string CustomAgentContext() => string.Join('\n', Get("host"), _service.GetConnectionSettings().Port.ToString(System.Globalization.CultureInfo.InvariantCulture), Get("username"), Get("key_path"), Get("known_hosts_path"));
    private bool CanChooseCustomAgent() => !_busy && _terminal?.IsConnected != true && !_terminalOpening;
    private bool CanInstallCustomAgent() => CanChooseCustomAgent() && _snapshot?.IsConnected == true &&
        _snapshot.ConnectionMode == "SSH" && CustomAgentConnectionMatches() && _customAgent is not null && _customAgentContext == CustomAgentContext();

    private bool CustomAgentConnectionMatches()
    {
        var saved = _service.GetConnectionSettings();
        return Get("host") == saved.Host && Get("username") == saved.Username &&
            Get("key_path") == saved.KeyPath && Get("known_hosts_path") == saved.KnownHostsPath;
    }

    private void BuildCustomAgent()
    {
        AddCard("Свой агент", "Установка локального исполняемого файла через SSH.", panel =>
        {
            panel.Children.Add(Muted("Выберите исполняемый ELF-файл Linux ARM64. Он заменит /data/zte-agent и будет запускаться с текущими параметрами и правами root. Используйте только доверенный файл. Проверка ELF и запуска процесса не подтверждает совместимость его API с веб-панелью, VPN и экраном модема."));
            var actions = new WrapPanel { Orientation = Orientation.Horizontal };
            _chooseCustomAgentButton = ActionButton("Выбрать файл агента…", ChooseCustomAgentAsync, false);
            _chooseCustomAgentButton.Name = "ChooseCustomAgent";
            _installCustomAgentButton = ActionButton("Установить выбранный агент", InstallSelectedAgentAsync, true);
            _installCustomAgentButton.Name = "InstallCustomAgent";
            actions.Children.Add(_chooseCustomAgentButton); actions.Children.Add(_installCustomAgentButton); panel.Children.Add(actions);
            if (_customAgent is { } candidate)
            {
                panel.Children.Add(ValueLine("Файл", candidate.FileName));
                panel.Children.Add(ValueLine("Размер", candidate.Bytes.ToString(System.Globalization.CultureInfo.InvariantCulture) + " B"));
                panel.Children.Add(ValueLine("SHA-256", candidate.Sha256));
                panel.Children.Add(ValueLine("Загрузчик", candidate.Interpreter ?? Localization.Translate("Статический ELF")));
            }
            panel.Children.Add(Muted("Сохраняется одна предыдущая копия агента. При ошибке запуска установщик выполняет откат; при неизвестном результате сохраните файлы восстановления. Веб-панель, VPN и дополнительные страницы автоматически не обновляются."));
        });
        UpdateCustomAgentAvailability();
    }

    private async Task ChooseCustomAgentAsync()
    {
        if (!CanChooseCustomAgent()) return;
        var context = CustomAgentContext();
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions {
            Title = Localization.Translate("Выбрать файл агента…"), AllowMultiple = false,
        });
        if (!CanChooseCustomAgent() || context != CustomAgentContext()) return;
        if (files.FirstOrDefault()?.TryGetLocalPath() is not { } path) return;
        SelectCustomAgent(path);
    }

    internal void SelectCustomAgent(string path)
    {
        if (!CanChooseCustomAgent()) return;
        _customAgent = null; _customAgentContext = null;
        try { _customAgent = AgentCandidate.Inspect(path); _customAgentContext = CustomAgentContext(); }
        finally { RenderPage(); }
    }

    private async Task InstallSelectedAgentAsync()
    {
        if (!CanInstallCustomAgent()) return;
        var candidate = _customAgent!;
        // Backend validates these exact bytes again before staging or mutation.
        try { _ = AgentCandidate.FromSelection(candidate.Path, candidate.Bytes, candidate.Sha256); }
        catch { _customAgent = null; _customAgentContext = null; RenderPage(); throw; }
        _esimAuthorized = false; _esimSnapshot = null; _esimCard = null; _esimSelected = null;
        await ExecuteAsync(ModemOperation.InstallCustomAgent, new Dictionary<string,string> {
            ["host"] = Get("host"), ["port"] = _service.GetConnectionSettings().Port.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["key_path"] = Get("key_path"), ["known_hosts_path"] = Get("known_hosts_path"),
            ["agent_path"] = candidate.Path, ["agent_sha256"] = candidate.Sha256,
            ["agent_bytes"] = candidate.Bytes.ToString(System.Globalization.CultureInfo.InvariantCulture),
        });
    }

    private void UpdateCustomAgentAvailability()
    {
        if (_chooseCustomAgentButton is not null) _chooseCustomAgentButton.IsEnabled = CanChooseCustomAgent();
        if (_installCustomAgentButton is not null) _installCustomAgentButton.IsEnabled = CanInstallCustomAgent();
    }
}
