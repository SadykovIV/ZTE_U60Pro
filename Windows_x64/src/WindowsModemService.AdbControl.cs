using ZteImeiStudio.Windows.Features;

namespace ZteImeiStudio.Windows;

public sealed partial class WindowsModemService
{
    private void ClearAdbState() => _snapshot = _snapshot with
    {
        AdbEnabled = null, AdbControlSupported = false,
        AdbStatus = "Состояние USB ADB не определено. Подключитесь по SSH и обновите состояние.",
    };
    private async Task<string> RefreshAdbStateAsync(CancellationToken ct)
    {
        ClearAdbState();
        RequireSsh(allowAdbPending: true);
        var state = await _features!.GetAdbControlStatusAsync(ct);
        _snapshot = _snapshot with
        {
            AdbEnabled = state.Enabled, AdbControlSupported = state.SupportsChange, AdbStatus = state.Detail,
        };
        return state.Detail;
    }
    private async Task<string> SetAdbEnabledAsync(IReadOnlyDictionary<string, string>? parameters, CancellationToken ct)
    {
        // Exact spelling; never let malformed/absent input become a disable.
        var value = parameters?.GetValueOrDefault("enabled");
        if (value is not ("true" or "false")) throw new ArgumentException("Укажите точное состояние ADB: true или false.");
        ClearAdbState();
        RequireSsh();
        var state = await _features!.SetAdbEnabledAsync(value == "true", ct);
        _snapshot = _snapshot with { AdbEnabled = state.Enabled, AdbControlSupported = state.SupportsChange, AdbStatus = state.Detail };
        return state.Detail;
    }
}
