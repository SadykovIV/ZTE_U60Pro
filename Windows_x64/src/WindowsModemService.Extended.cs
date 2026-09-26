using ZteImeiStudio.Windows.Features;

namespace ZteImeiStudio.Windows;

public sealed partial class WindowsModemService
{
    private string? _opkgFeedsGeneration;

    private partial async Task<IReadOnlyList<ModemAppInfo>> ListApplicationsExtendedAsync(CancellationToken ct)
    {
        RequireSsh();
        var inventory = await _features!.GetApplicationsAsync(ct);
        _snapshot = _snapshot with { Storage = $"/data: {inventory.DataFreeKiB / 1024} МиБ свободно" };
        var applications = inventory.Catalog.Select(app => new ModemAppInfo(
            app.Id, app.Name, app.Version, app.Installed, app.Description)).ToList();
        try
        {
            var opkg = await _features.GetPrivateOpkgStatusAsync(ct);
            applications.Add(new ModemAppInfo("opkg", "opkg", "экспериментально", opkg.Installed,
                "Изолированный менеджер пакетов OpenWrt для /data."));
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            applications.Add(new ModemAppInfo("opkg", "opkg", "экспериментально", false,
                "Состояние менеджера пакетов не удалось проверить. Откройте Terminal для диагностики.", false));
        }
        // The stock package DB is read-only here; it still belongs in the
        // installed inventory so users can inspect what their firmware ships.
        applications.AddRange(inventory.InstalledPackages.Select(package => new ModemAppInfo(
            "stock:" + package.Name, package.Name, package.Version, true, "Штатный пакет прошивки (только просмотр)")));
        return applications;
    }

    private partial async Task<string> RunExtendedAsync(OperationRequest request, CancellationToken ct)
    {
        if (request.Operation is not (ModemOperation.VerifyDeviceBackup or ModemOperation.VerifySystemBackup or ModemOperation.ExportDiagnostics)) RequireSsh();
        var p = request.Parameters;
        switch (request.Operation)
        {
            case ModemOperation.InstallApplication:
            {
                var id = Param(p, "id");
                if (id == "opkg")
                {
                    var installed = await _features!.InstallPrivateOpkgAsync(ct);
                    return installed.Output.Length > 0 ? installed.Output : "Изолированный opkg установлен.";
                }
                if (id == "ssclash")
                {
                    var password = p?.GetValueOrDefault("ssclash_password") ?? "";
                    var inventory = await _features!.InstallSsclashAsync(password, _host, ct);
                    return inventory.SsclashInstalled ? "SSClash-Go установлен и запущен; прокси выключен." : "Установка SSClash требует проверки.";
                }
                if (new[] { "htop", "iperf3", "mtr", "tcpdump" }.Contains(id))
                {
                    var status = await _features!.InstallDiagnosticToolsAsync(id, ct);
                    return status.Selected.Contains(id) ? id + " установлен в изолированный набор диагностики." : "Установка утилиты требует проверки.";
                }
                throw new InvalidDataException("Приложение не входит в проверенный каталог установки.");
            }
            case ModemOperation.RemoveApplication:
            {
                var id = Param(p, "id");
                if (id == "opkg")
                {
                    var removed = await _features!.RemovePrivateOpkgAsync(ct);
                    _opkgFeedsGeneration = null;
                    return removed.Output.Length > 0 ? removed.Output : "Изолированный opkg удалён.";
                }
                if (id == "ssclash")
                {
                    var removed = await _features!.RemoveSsclashAsync(Path.Combine(_storage, "Backups", "SSClash"), ct);
                    return "SSClash удалён. Резервная копия: " + removed.LocalArchive;
                }
                if (new[] { "htop", "iperf3", "mtr", "tcpdump" }.Contains(id))
                {
                    var status = await _features!.RemoveDiagnosticToolsAsync(id, ct);
                    return !status.Selected.Contains(id) ? id + " удалён из диагностического набора." : "Удаление утилиты требует проверки.";
                }
                if (id.StartsWith("stock:", StringComparison.Ordinal)) throw new InvalidDataException("Штатные пакеты прошивки через это меню не удаляются.");
                throw new InvalidDataException("Неизвестное приложение.");
            }
            case ModemOperation.RefreshOpkg:
            {
                var status = await _features!.GetPrivateOpkgStatusAsync(ct);
                return status.Installed
                    ? $"Изолированный opkg установлен · {status.Packages.Count} пакетов · {status.FreeKiB / 1024} МиБ свободно."
                    : "Изолированный opkg ещё не установлен.";
            }
            case ModemOperation.InstallOpkg:
            {
                var result = await _features!.InstallPrivateOpkgAsync(ct);
                return result.Output.Length > 0 ? result.Output : result.Status.Installed ? "Изолированный opkg установлен." : "Установка opkg требует проверки.";
            }
            case ModemOperation.RemoveOpkg:
            {
                var result = await _features!.RemovePrivateOpkgAsync(ct);
                _opkgFeedsGeneration = null;
                return result.Output.Length > 0 ? result.Output : "Изолированный opkg удалён.";
            }
            case ModemOperation.RunOpkgCommand:
            {
                var line = Param(p, "command");
                if (line.StartsWith("opkg ", StringComparison.Ordinal)) line = line[5..];
                var result = await _features!.RunPrivateOpkgCommandAsync(line, ct);
                return result.Output.Length > 0 ? result.Output : "Команда opkg завершена. Установлено пакетов: " + result.Status.Packages.Count;
            }
            case ModemOperation.LoadOpkgFeeds:
            {
                var feeds = await _features!.ReadPrivateOpkgFeedsAsync(ct);
                _opkgFeedsGeneration = feeds.Generation;
                _operationValues = new Dictionary<string, string> { ["feeds"] = feeds.Text };
                return $"Загружено источников opkg. Прошивка {feeds.Release}, архитектура {feeds.Architecture}, доверенных ключей: {feeds.KeyFingerprints.Count}.";
            }
            case ModemOperation.SaveOpkgFeeds:
            {
                if (_opkgFeedsGeneration == null) throw new InvalidOperationException("Сначала прочитайте текущие источники opkg с модема.");
                var text = p?.GetValueOrDefault("feeds") ?? "";
                var result = await _features!.SavePrivateOpkgFeedsAsync(text, _opkgFeedsGeneration, ct);
                _opkgFeedsGeneration = result.Status.Generation;
                _operationValues = new Dictionary<string, string> { ["feeds"] = DeviceFeatureService.NormalizeFeeds(text) };
                return result.Output.Length > 0 ? result.Output : "Источники opkg сохранены. Выполните update для проверки подписанных индексов.";
            }
            default:
                return await RunOtherExtendedAsync(request, ct);
        }
    }

    private partial Task<string> RunOtherExtendedAsync(OperationRequest request, CancellationToken ct);
}
